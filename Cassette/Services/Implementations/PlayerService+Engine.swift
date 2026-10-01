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
    // MARK: - Playback engine (AudioStreaming vs AVPlayer Spatial)

    func startEnginePlayback(
        url: URL,
        headers: [String: String],
        useSystemPlayer: Bool
    ) {
        #if os(macOS)
        let useAVPlayer = true
        #else
        let useAVPlayer = useSystemPlayer
        #endif

        if useAVPlayer {
            engine.stop()
            tearDownSystemPlayer()
            usingSystemPlayer = true
            Task { @MainActor in PlaybackBeatMeter.shared.setEnabled(false) }

            #if os(iOS)
            // Re-assert multichannel / Spatial Audio session before AVPlayer starts decoding.
            configureAudioSessionIfNeeded(preferMultichannel: true)
            #endif

            let restoreInfo = pendingRestoreInfo
            pendingRestoreInfo = nil
            if restoreInfo != nil { isRestoringSession = false }
            systemEngine.volume = restoredVolume
            systemEngine.start(url: url, headers: headers, generation: systemPlayerGeneration,
                               position: restoreInfo?.seekTime ?? 0, paused: restoreInfo?.pause ?? false)
            logSpatialRouteStatus()
        } else {
            #if !os(macOS)
            // macOS always routes through AVPlayer (`useAVPlayer` is constant `true`),
            // so this branch only exists on iOS.
            tearDownSystemPlayer()
            usingSystemPlayer = false
            engine.play(url: url, headers: headers)
            Task { @MainActor in PlaybackBeatMeter.shared.setEnabled(true) }
            #endif
        }
    }

    func handleSystemEngineEvent(_ event: AVPlayerPlaybackEngine.Event) async {
        switch event {
        case .itemChanged(let generation): await handleSystemPlayerItemChanged(generation: generation)
        case .ended(let generation, let itemID): await handleSystemPlayerDidReachEnd(generation: generation, itemID: itemID)
        case .failed(let generation, let itemID):
            guard systemEngine.observedItemID == itemID else { return }
            await handleSystemPlayerFailure(generation: generation)
        case .timeControl(let generation, let status): await handleSystemPlayerTimeControlStatus(status, generation: generation)
        case .stalled(let generation):
            guard generation == systemPlayerGeneration, !didRecoverFromStalledStream,
                  pendingSeekTarget == nil, Date() >= seekSettleDeadline else { return }
            await recoverFromStalledStream()
        }
    }

    private func handleSystemPlayerItemChanged(generation: UInt64) async {
        guard generation == systemPlayerGeneration, usingSystemPlayer,
              !isHandlingEndOfTrack, systemEngine.consumeQueuedTransition() else { return }
        isHandlingEndOfTrack = true
        defer { isHandlingEndOfTrack = false }
        stopSystemPlayerProgressWatchdog()
        bridgedEntryDidStart = true
        _ = await finalizeGaplessBridge(epoch: playbackEpoch)
        guard generation == systemPlayerGeneration else { return }
        startSystemPlayerProgressWatchdog(generation: generation)
    }

    func tearDownSystemPlayer() {
        cancelGaplessBridge()
        systemPlayerGeneration &+= 1
        systemEngine.stop()
    }

    func startSystemPlayerProgressWatchdog(generation: UInt64) {
        guard currentSource?.isLiveStream != true else { return }
        systemEngine.startWatchdog(generation: generation)
    }
    func stopSystemPlayerProgressWatchdog() { systemEngine.stopWatchdog() }

    /// One Automatic-only quality retry after sustained lack of progress, with a session cooldown.
    /// Every suspension is fenced by both the selection epoch and the AVPlayer generation.
    private func recoverFromStalledStream() async {
        let epoch = playbackEpoch
        let generation = systemPlayerGeneration
        guard usingSystemPlayer, !isTrackTransitionPending,
              let source = currentSource, !source.isLocal, !source.isLiveStream else { return }
        let context = await MainActor.run {
            (state.currentTrack, serverService.state.activeServer?.id, state.position,
             streamingSettings.formatForCurrentNetwork(
                isLimited: serverService.state.isExpensive || serverService.state.isNetworkConstrained
             ), streamingSettings.adaptiveCeiling)
        }
        guard epoch == playbackEpoch, generation == systemPlayerGeneration, !Task.isCancelled,
              let song = context.0, let serverId = context.1 else { return }
        // Never destroy an explicit lossless/bitstream request to hide a slow connection. The
        // playback method is always automatic now, so only the quality choice can block the step-down.
        guard context.3 == .matchStream,
              !AudioQualityClassifier.shouldSkipTranscoding(song),
              let next = AdaptiveQualityPolicy.lowerTier(context.4 ?? context.3) else {
            didRecoverFromStalledStream = true
            return
        }
        guard Date().timeIntervalSince(lastStallRecoveryAt) >= 30 else { return }
        didRecoverFromStalledStream = true
        lastStallRecoveryAt = Date()
        await MainActor.run {
            streamingSettings.adaptiveCeiling = next
            streamingSettings.adaptiveCeilingAppliesToExplicitChoice = false
        }
        guard epoch == playbackEpoch, generation == systemPlayerGeneration, !Task.isCancelled else { return }
        Logger.player.warning("[STALL] sustained stall — retrying Automatic at \(next.rawValue, privacy: .public)")
        do {
            let resolved = try await mediaResolver.resolve(songId: song.id, serverId: serverId, song: song)
            guard epoch == playbackEpoch, generation == systemPlayerGeneration,
                  usingSystemPlayer, !Task.isCancelled else { return }
            currentSource = resolved
            pendingRestoreInfo = (seekTime: context.2, pause: false)
            await MainActor.run { state.playbackState = .loading }
            guard epoch == playbackEpoch, generation == systemPlayerGeneration, !Task.isCancelled else { return }
            startEnginePlayback(url: resolved.url, headers: resolved.customHeaders, useSystemPlayer: true)
            startProgressTimer()
        } catch {
            guard epoch == playbackEpoch, generation == systemPlayerGeneration, !Task.isCancelled else { return }
            Logger.player.error("[STALL] retry resolve failed: \(error, privacy: .public)")
            await MainActor.run { state.playbackState = .error(.timeout) }
        }
    }

    func stopEngine() {
        if usingSystemPlayer {
            tearDownSystemPlayer()
            usingSystemPlayer = false
        }
        engine.stop()
        Task { @MainActor in PlaybackBeatMeter.shared.setEnabled(false) }
    }

    var activeEngine: any PlaybackEngine { usingSystemPlayer ? systemEngine : engine }

    func pauseEngine() {
        activeEngine.pause()
        Task { @MainActor in PlaybackBeatMeter.shared.setEnabled(false) }
    }
    func seekEngine(to position: TimeInterval) { activeEngine.seek(to: position) }
    func engineProgress() -> Double { activeEngine.progress }
    func engineDuration() -> Double { activeEngine.duration }
    func engineIsSeekable() -> Bool { activeEngine.isSeekable }
    func engineVolume() -> Float { activeEngine.volume }
    func setEngineVolume(_ volume: Float) { activeEngine.volume = volume }

    private func handleSystemPlayerFailure(generation: UInt64) async {
        guard usingSystemPlayer, generation == systemPlayerGeneration else { return }
        let isLive = await MainActor.run { state.isLiveStream }
        guard usingSystemPlayer, generation == systemPlayerGeneration else { return }
        if isLive {
            let name = await MainActor.run { state.currentRadio?.name ?? "" }
            await handleLiveStreamFailure(stationName: name, error: nil)
        } else {
            stopProgressTimer()
            tearDownSystemPlayer()
            await MainActor.run { state.playbackState = .error(.timeout) }
        }
    }

    private func handleSystemPlayerDidReachEnd(generation: UInt64, itemID: ObjectIdentifier) async {
        guard usingSystemPlayer, generation == systemPlayerGeneration,
              systemEngine.observedItemID == itemID else { return }
        if systemEngine.hasQueuedItem {
            await handleSystemPlayerItemChanged(generation: generation)
            return
        }
        let liveStation = await MainActor.run { state.currentRadio?.name }
        guard usingSystemPlayer, generation == systemPlayerGeneration else { return }
        if let liveStation {
            await handleLiveStreamFailure(stationName: liveStation, error: nil)
        } else {
            await handleEndOfTrack(engineConfirmed: true)
        }
    }

    private func handleSystemPlayerTimeControlStatus(_ rawStatus: Int, generation: UInt64) async {
        guard usingSystemPlayer, generation == systemPlayerGeneration,
              let status = AVPlayer.TimeControlStatus(rawValue: rawStatus),
              systemEngine.timeControlStatus == status else { return }

        switch status {
        case .playing:
            let limited = await MainActor.run { serverService.state.isLimitedNetwork }
            guard generation == systemPlayerGeneration, !isTrackTransitionPending,
                  systemEngine.timeControlStatus == .playing else { return }
            systemEngine.setForwardBuffer(PlaybackBufferPolicy.forwardBuffer(
                isLocal: currentSource?.isLocal == true, isLimited: limited
            ))
            // A state notification is not proof of output: the watchdog also observes media time.
            startSystemPlayerProgressWatchdog(generation: generation)
            if let requested = lastTransitionRequestedAt {
                lastTransitionRequestedAt = nil
                Logger.player.info(
                    "[TRANSITION-TIMING] AVPlayer audio started \(Int(Date().timeIntervalSince(requested) * 1000), privacy: .public)ms after the request"
                )
            }
            let seekable = engineIsSeekable()
            await MainActor.run {
                state.playbackState = .playing
                state.isPlaybackAvailable = true
                state.isSeekable = seekable
            }
        case .waitingToPlayAtSpecifiedRate:
            // Throttled diagnostics: "no audio at all" from the AVPlayer path is almost always this
            // state, and the buffered amount tells us whether the incoming stream is simply faster than
            // the link (a hi-res lossless original on a slower connection).
            let buffered = systemEngine.bufferedDuration
            let likely = systemEngine.isLikelyToKeepUp
            if Date().timeIntervalSince(lastSystemPlayerWaitingLogAt) >= 2 {
                lastSystemPlayerWaitingLogAt = Date()
                Logger.player.warning(
                    "[AVPLAYER] waiting to play — buffered \(buffered, format: .fixed(precision: 1))s likelyToKeepUp=\(likely, privacy: .public)"
                )
            }
            startSystemPlayerProgressWatchdog(generation: generation)
            await MainActor.run {
                if state.playbackState != .paused {
                    state.playbackState = .loading
                }
            }
        case .paused:
            break
        @unknown default:
            break
        }
    }

    /// Publishes the "an engine is really producing audio" confirmation.
    ///
    /// A fresh track is published as `.loading`, and `.playing` is published only once an engine
    /// has actually started: the transport must never show its pause/stop control for a stream
    /// that has not produced a sample yet (see `PlaybackState.controlAppearance`). Three
    /// independent confirmations call this — AVPlayer's time-control status, AudioStreaming's
    /// state callback, and measured engine progress in the progress ticker.
    ///
    /// Promotes `.loading` only. A user pause that landed while the stream was still opening has
    /// already written `.paused`, and a session restore that is about to pause itself must not
    /// flash the pause control on its way there.
    func publishEnginePlaybackConfirmation() async {
        let restoringIntoPause = pendingRestoreInfo?.pause == true
        await MainActor.run {
            guard let promoted = state.playbackState.confirmingPlayback(
                restoringIntoPause: restoringIntoPause
            ) else { return }
            state.playbackState = promoted
            Logger.player.debug("[PLAYER] engine confirmed playback — publishing .playing")
        }
    }

    func logSpatialRouteStatus() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        let spatialEnabled = session.currentRoute.outputs.contains(where: \.isSpatialAudioEnabled)
        let channels = session.maximumOutputNumberOfChannels
        Logger.player.info(
            "[SPATIAL] route spatialEnabled=\(spatialEnabled, privacy: .public) maxChannels=\(channels, privacy: .public) supportsMultichannel=\(session.supportsMultichannelContent, privacy: .public)"
        )
        #endif
    }
}
