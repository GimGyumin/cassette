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
    func handleBufferUnderrun() async {
        guard !usingSystemPlayer, !isTrackTransitionPending,
              pendingSeekTarget == nil, Date() >= seekSettleDeadline else { return }
        let epoch = playbackEpoch
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

    func handleAudioStateChanged(_ newState: AudioPlayerState) async {
        // AudioStreaming can deliver queued callbacks after a switch to AVPlayer.
        // Those callbacks must never consume the system player's pending restore.
        guard !usingSystemPlayer, !isTrackTransitionPending, engine.state == newState else { return }
        switch newState {
        case .playing:
            if let requested = lastTransitionRequestedAt {
                lastTransitionRequestedAt = nil
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
            guard let info = pendingRestoreInfo else { break }
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
                guard !Task.isCancelled else { return }
                restorePauseTask = nil
                pauseEngine()
                setEngineVolume(restoredVolume)
                isMutedForRestore = false
                await MainActor.run { state.playbackState = .paused }
                stopProgressTimer()
                isRestoringSession = false
                Logger.player.info("[RESTORE] seek landed — paused")
            }
        case .error:
            Logger.player.error("[PLAYER] AudioStreaming entered error state")
            let isLive = await MainActor.run { state.isLiveStream }
            if isLive {
                let name = await MainActor.run { state.currentRadio?.name ?? "" }
                await handleLiveStreamFailure(stationName: name, error: nil)
            } else {
                await MainActor.run { state.playbackState = .error(.timeout) }
            }
        default:
            break
        }
    }

    func handleAudioError(_ error: AudioPlayerError) async {
        guard !usingSystemPlayer, !isTrackTransitionPending, engine.state == .error else { return }
        Logger.player.error("[PLAYER] AudioStreaming unexpected error")
        let isLive = await MainActor.run { state.isLiveStream }
        if isLive {
            let name = await MainActor.run { state.currentRadio?.name ?? "" }
            await handleLiveStreamFailure(stationName: name, error: nil)
        } else {
            await MainActor.run { state.playbackState = .error(.timeout) }
        }
    }
}
