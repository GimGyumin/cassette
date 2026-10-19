// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import AudioStreaming
import SwiftSonic
import OSLog
import AVFoundation

#if os(iOS)
import AVFAudio
import UIKit
#endif

// Actor-isolated implementation; PlayerService remains the single playback owner.
extension PlayerService {
    // MARK: - Delegate callbacks

    /// The engine re-buffered mid-track: the link is not keeping up with the chosen rate.
    ///
    /// One underrun is a hiccup; two inside the same track mean the Automatic pick is too high for
    /// this link. Lower the session ceiling so the next resolve transcodes lower, and publish the
    /// link as slow — which is what makes a throttled Wi-Fi link behave like cellular even though
    /// iOS reports it as unmetered. An explicit quality choice is never touched.
    func handleBufferUnderrun(expectedContext: PlaybackContext? = nil) async {
        guard expectedContext == nil || expectedContext == playbackContext else { return }
        guard !systemPlayback.isActive, !isTrackTransitionPending,
              seekState == .idle, Date() >= systemPlayback.seekSettleDeadline else { return }
        let epoch = playbackEpoch
        let progress = engineProgress()
        // AudioStreaming also emits playing → buffering while selecting/prebuffering a
        // queued entry. Let that transient settle before cancelling its prepared audio.
        do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
        guard epoch == playbackEpoch, engine.state == .bufferring,
              !systemPlayback.isActive, expectedContext == nil || expectedContext == playbackContext,
              !isHandlingEndOfTrack, !gaplessBridge.wasSelected,
              abs(engineProgress() - progress) < 0.01 else { return }
        Logger.player.warning("[NET-AUDIO] sustained underrun — engine=AudioStreaming epoch=\(epoch) position=\(progress, format: .fixed(precision: 2))s")
        // Audible playback owns the bandwidth when a buffer runs dry.
        cancelPendingCacheDownload()
        cancelPendingPrefetch()
        cancelGaplessBridge()
        nextGaplessPreparationAttempt = Date().addingTimeInterval(10)
        underrunCountForCurrentTrack += 1
        guard underrunCountForCurrentTrack >= 2, !didAdaptQualityForCurrentTrack else { return }

        let (isLiveStream, configured, ceiling, limited) = await MainActor.run {
            let limited = serverService.state.isLimitedNetwork
            return (
                state.isLiveStream,
                streamingSettings.formatForCurrentNetwork(
                    isLimited: serverService.state.isExpensive || serverService.state.isNetworkConstrained
                ),
                streamingSettings.adaptiveCeiling,
                limited
            )
        }
        guard !isLiveStream, epoch == playbackEpoch else { return }
        // Only Automatic adapts: an explicit quality is the user's instruction.
        guard configured == .matchStream else { return }
        let currentCeiling = ceiling ?? .matchStream
        guard let next = AdaptiveQualityPolicy.lowerTier(currentCeiling) else { return }

        didAdaptQualityForCurrentTrack = true
        await MainActor.run {
            streamingSettings.adaptiveCeiling = next
            // An underrun is a hiccup, not proof: this ceiling still respects an explicit choice.
            streamingSettings.adaptiveCeilingAppliesToExplicitChoice = false
            if !NetworkCostPolicy.isSlow(measuredBytesPerSecond: serverService.state.measuredBytesPerSecond) {
                serverService.state.measuredBytesPerSecond = NetworkCostPolicy.slowBytesPerSecond * 0.5
            }
        }
        Logger.player.warning(
            "[ADAPT] underruns=\(self.underrunCountForCurrentTrack, privacy: .public) limited=\(limited, privacy: .public) — Automatic ceiling lowered to \(next.rawValue, privacy: .public)"
        )
    }

    func handleAudioStateChanged(_ newState: AudioPlayerState, expectedContext: PlaybackContext? = nil) async {
        guard expectedContext == nil || expectedContext == playbackContext else { return }
        // AudioStreaming can deliver queued callbacks after a switch to AVPlayer.
        // Those callbacks must never consume the system player's pending restore.
        guard !systemPlayback.isActive, !isTrackTransitionPending, engine.state == newState else { return }
        let epoch = playbackEpoch
        let context = playbackContext
        switch newState {
        case .bufferring:
            await publishEngineWaiting()
        case .playing:
            if let requested = systemPlayback.transitionRequestedAt {
                systemPlayback.transitionRequestedAt = nil
                Logger.player.info("[TRANSITION-TIMING] AudioStreaming playback began \(Int(Date().timeIntervalSince(requested) * 1000), privacy: .public)ms after request")
            }
            let parsedDuration = engineDuration()
            let knownDuration = await MainActor.run { state.duration }
            let seekable = engineIsSeekable() || (parsedDuration <= 0 && knownDuration > 0)
            await MainActor.run { state.isSeekable = seekable }
            // The engine produced its first sample: this is AudioStreaming's half of the
            // "audio is really flowing" confirmation. A fresh play is published as `.loading`,
            // and this is what ends it — never the pause/stop control, because nothing was
            // playable before this point.
            await publishEnginePlaybackConfirmation()
            guard epoch == playbackEpoch, !systemPlayback.isActive,
                  !isTrackTransitionPending, engine.state == .playing else { return }
            guard let info = pendingRestoreInfo else { break }
            // Some remote streams produce samples before AudioStreaming can seek.
            // Dropping the restore at that point silently replays the song from zero.
            // Let AVPlayer open and seek the same source with the restore still armed.
            if info.seekTime > 1, !engineIsSeekable(), let source = currentSource {
                seekState = .settling(target: info.seekTime, deadline: Date().addingTimeInterval(12))
                lastObservedEngineProgress = info.seekTime
                startEnginePlayback(
                    url: source.url,
                    headers: source.customHeaders,
                    useSystemPlayer: true
                )
                return
            }
            pendingRestoreInfo = nil
            if engineIsSeekable() && info.seekTime > 1 {
                seekEngine(to: info.seekTime)
            }
            guard info.pause else {
                isRestoringSession = false
                break
            }
            restorePauseTask = Task {
                try? await Task.sleep(for: .milliseconds(150))
                guard contextIsCurrent(context) else { return }
                restorePauseTask = nil
                pauseEngine()
                setEngineVolume(restoredVolume)
                isMutedForRestore = false
                guard await commitPresentation(context, { state in state.playbackState = .paused; return true }) else { return }
                stopProgressTimer()
                isRestoringSession = false
                Logger.player.info("[RESTORE] seek landed — paused")
            }
        case .error:
            // The dependency queues a status callback before its typed error callback.
            // Coalesce them without replacing the real cause with a fabricated timeout.
            engineFailureTask?.cancel()
            engineFailureTask = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                await self?.handleAudioError(.other, expectedContext: context)
            }
        default:
            break
        }
    }

    func handleAudioError(_ error: AudioPlayerError, expectedContext: PlaybackContext? = nil) async {
        let context = expectedContext ?? playbackContext
        guard contextIsCurrent(context), !systemPlayback.isActive,
              !isTrackTransitionPending, engine.state == .error else { return }
        // A status-only fallback may itself own engineFailureTask. Commit before cancelling it.
        let pending = engineFailureTask
        engineFailureTask = nil
        let failure = PlaybackFailure.classify(error)
        guard failure.kind != .cancelled else { pending?.cancel(); return }
        let liveStation = await MainActor.run { state.isLiveStream ? state.currentRadio?.name : nil }
        guard context == playbackContext else { pending?.cancel(); return }
        if let liveStation {
            await handleLiveStreamFailure(stationName: liveStation, error: failure)
        } else if !(await recoverFailedCachedPlayback(context: context)) {
            await finishPlaybackFailure(.playbackFailed(failure), context: context)
        }
        pending?.cancel()
    }
}
