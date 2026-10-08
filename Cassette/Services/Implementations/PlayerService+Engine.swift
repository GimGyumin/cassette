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
        let restoreInfo = pendingRestoreInfo
        let transcodeRequest = currentSource?.transcodeRequest(at: restoreInfo?.seekTime ?? 0)
        let requestURL = transcodeRequest?.url ?? url
        streamTimeOffset = transcodeRequest?.offset ?? 0
        #if os(macOS)
        let useAVPlayer = true
        #else
        let useAVPlayer = useSystemPlayer
        #endif

        if useAVPlayer {
            engine.stop()
            tearDownSystemPlayer()
            systemPlayback.isActive = true
            Task { @MainActor in PlaybackBeatMeter.shared.setEnabled(false) }

            #if os(iOS)
            // Re-assert multichannel / Spatial Audio session before AVPlayer starts decoding.
            configureAudioSessionIfNeeded(preferMultichannel: true)
            #endif

            pendingRestoreInfo = nil
            if restoreInfo != nil { isRestoringSession = false }
            systemEngine.volume = restoredVolume
            systemEngine.start(url: requestURL, headers: headers, generation: systemPlayback.generation,
                               position: transcodeRequest == nil ? (restoreInfo?.seekTime ?? 0) : 0,
                               paused: restoreInfo?.pause ?? false)
            logSpatialRouteStatus()
        } else {
            #if !os(macOS)
            // macOS always routes through AVPlayer (`useAVPlayer` is constant `true`),
            // so this branch only exists on iOS.
            tearDownSystemPlayer()
            systemPlayback.isActive = false
            if transcodeRequest != nil {
                pendingRestoreInfo = restoreInfo?.pause == true ? (seekTime: 0, pause: true) : nil
            }
            engine.play(url: requestURL, headers: headers)
            if restoreInfo?.pause == true, transcodeRequest != nil { engine.pause() }
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
            guard generation == systemPlayback.generation, !systemPlayback.recoveredCurrentStall,
                  seekState == .idle, Date() >= systemPlayback.seekSettleDeadline else { return }
            await recoverFromStalledStream()
        }
    }

    func handleSystemPlayerItemChanged(generation: UInt64) async {
        guard generation == systemPlayback.generation, systemPlayback.isActive,
              !isHandlingEndOfTrack, systemEngine.consumeQueuedTransition() else { return }
        isHandlingEndOfTrack = true
        defer { isHandlingEndOfTrack = false }
        stopSystemPlayerProgressWatchdog()
        gaplessBridge.wasSelected = true
        _ = await finalizeGaplessBridge(epoch: playbackEpoch)
        guard generation == systemPlayback.generation else { return }
        startSystemPlayerProgressWatchdog(generation: generation)
    }

    func tearDownSystemPlayer() {
        cancelGaplessBridge()
        systemPlayback.invalidateCallbacks()
        systemEngine.stop()
    }

    func startSystemPlayerProgressWatchdog(generation: UInt64) {
        guard currentSource?.isLiveStream != true else { return }
        systemEngine.startWatchdog(generation: generation)
    }
    func stopSystemPlayerProgressWatchdog() { systemEngine.stopWatchdog() }

    nonisolated static func isPrematureTranscodeEnd(duration: Double, offset: Double, position: Double) -> Bool {
        duration.isFinite && offset.isFinite && position.isFinite
            && duration - offset > 30 && position >= offset && position - offset < 3
    }

    func recoverPrematureTranscodeEnd(position: Double) async {
        let epoch = playbackEpoch
        guard let source = currentSource else { return }
        let snapshot = await MainActor.run { (state.currentTrack, state.playbackState) }
        guard epoch == playbackEpoch, snapshot.1.hasPlaybackIntent, let song = snapshot.0 else { return }
        if systemPlayback.recoveredCurrentStall {
            stopProgressTimer()
            stopEngine()
            pendingRestoreInfo = (seekTime: position, pause: false)
            await MainActor.run { state.playbackState = .error(.timeout) }
            return
        }
        systemPlayback.recoveredCurrentStall = true
        await restartAcquiringPlayback(song: song, source: source, epoch: epoch,
                                       reason: "truncated transcode response")
        scheduleStallRecoveryCompletion(songID: song.id, epoch: epoch, position: position)
    }

    /// Retry once after a sustained stall, retaining the current item while resolving its replacement.
    func recoverFromStalledStream() async {
        let epoch = playbackEpoch
        let generation = systemPlayback.generation
        let stalledProgress = engineProgress()
        // Opening a fresh track has its own bounded acquisition task.
        guard stalledProgress >= 0.25 else { return }
        guard !systemPlayback.recoveredCurrentStall, !isTrackTransitionPending,
              seekState == .idle, Date() >= systemPlayback.seekSettleDeadline,
              let source = currentSource, !source.isLocal, !source.isLiveStream else { return }
        let context = await MainActor.run {
            (state.currentTrack, serverService.state.activeServer?.id,
             streamingSettings.formatForCurrentNetwork(
                isLimited: serverService.state.isExpensive || serverService.state.isNetworkConstrained
             ), streamingSettings.adaptiveCeiling, state.playbackState)
        }
        guard epoch == playbackEpoch, generation == systemPlayback.generation, !Task.isCancelled,
              !systemPlayback.recoveredCurrentStall,
              context.4.hasPlaybackIntent,
              let song = context.0, let serverId = context.1 else { return }
        systemPlayback.recoveredCurrentStall = true
        if await recoverAcquiringPlaybackFromLocalMedia(
            song: song,
            serverId: serverId,
            expectedEpoch: epoch,
            reason: "stream stalled"
        ) {
            return
        }
        // Never destroy an explicit lossless/bitstream request to hide a slow connection. The
        // playback method is always automatic now, so only the quality choice can block the step-down.
        systemPlayback.lastStallRecoveryAt = Date()
        if context.2 == .matchStream, !AudioQualityClassifier.shouldSkipTranscoding(song),
           let next = AdaptiveQualityPolicy.lowerTier(context.3 ?? context.2) {
            await MainActor.run {
                streamingSettings.adaptiveCeiling = next
                streamingSettings.adaptiveCeilingAppliesToExplicitChoice = false
            }
        }
        do {
            let refreshed = try await mediaResolver.resolve(songId: song.id, serverId: serverId, song: song)
            let playbackState = await MainActor.run { state.playbackState }
            guard epoch == playbackEpoch, generation == systemPlayback.generation,
                  !Task.isCancelled, !isTrackTransitionPending, seekState == .idle,
                  Date() >= systemPlayback.seekSettleDeadline,
                  playbackState.hasPlaybackIntent,
                  engineProgress() <= stalledProgress + 0.1 else { return }
            await restartAcquiringPlayback(song: song, source: refreshed, epoch: epoch,
                                           reason: "sustained playback stall")
            scheduleStallRecoveryCompletion(songID: song.id, epoch: epoch, position: stalledProgress)
        } catch {
            Logger.player.error("[STALL] source refresh failed: \(error, privacy: .public)")
        }
    }

    func scheduleStallRecoveryCompletion(songID: String, epoch: UInt64, position: Double) {
        playbackAcquisitionTask?.cancel()
        playbackAcquisitionTask = Task { [weak self] in
            guard let self else { return }
            for _ in 0..<30 {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard epoch == (await self.playbackEpoch) else { return }
                let snapshot = await MainActor.run { (self.state.currentTrack?.id, self.state.playbackState) }
                guard epoch == (await self.playbackEpoch), snapshot.0 == songID,
                      snapshot.1.hasPlaybackIntent else { return }
                if await self.engineProgress() > position + 0.25 { return }
            }
            guard epoch == (await self.playbackEpoch), !Task.isCancelled else { return }
            await self.failPlaybackAcquisition(songID: songID, epoch: epoch)
        }
    }

    /// A finite stream must not remain in acquisition forever. First prefer a completed download
    /// or cache entry; if neither exists after the initial window, refresh the source once. The
    /// epoch and track id fence every suspension so a late recovery cannot replace a newer song.
    func schedulePlaybackAcquisitionRecovery(song: DisplayableSong, serverId: UUID, epoch: UInt64) {
        playbackAcquisitionTask?.cancel()
        playbackAcquisitionTask = Task { [weak self] in
            guard let self else { return }
            // Real-device logs show large lossless originals legitimately taking 8–14 seconds
            // to open. Poll for a finished local file during that window, but do not create a
            // second remote request until 15 seconds have elapsed.
            for _ in 0..<5 {
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                guard await self.isPlaybackStillAcquiring(songID: song.id, epoch: epoch) else { return }
                if await self.recoverAcquiringPlaybackFromLocalMedia(
                    song: song,
                    serverId: serverId,
                    expectedEpoch: epoch,
                    reason: "local media became available while opening stream"
                ) {
                    return
                }
            }

            do {
                let refreshed = try await self.mediaResolver.resolve(
                    songId: song.id,
                    serverId: serverId,
                    song: song
                )
                guard await self.isPlaybackStillAcquiring(songID: song.id, epoch: epoch) else { return }
                await self.restartAcquiringPlayback(
                    song: song,
                    source: refreshed,
                    epoch: epoch,
                    reason: "refreshed stalled source"
                )
            } catch {
                guard await self.isPlaybackStillAcquiring(songID: song.id, epoch: epoch) else { return }
                Logger.player.error("[ACQUIRE] source refresh failed for '\(song.id, privacy: .public)': \(error, privacy: .public)")
            }

            // Give the single refreshed request a generous window, while continuing to notice a
            // download that finishes in parallel. End with an actionable timeout instead of an
            // endless loading state.
            for _ in 0..<10 {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard await self.isPlaybackStillAcquiring(songID: song.id, epoch: epoch) else { return }
                if await self.recoverAcquiringPlaybackFromLocalMedia(
                    song: song,
                    serverId: serverId,
                    expectedEpoch: epoch,
                    reason: "download completed during retry"
                ) {
                    return
                }
            }
            guard await self.isPlaybackStillAcquiring(songID: song.id, epoch: epoch) else { return }
            await self.failPlaybackAcquisition(songID: song.id, epoch: epoch)
        }
    }

    /// Pure gate used by recovery and tests. A transition may report `.playing` to preserve the
    /// transport appearance, so a non-advancing clock is also treated as acquisition.
    nonisolated static func shouldRecoverAcquiringPlayback(
        trackMatches: Bool,
        playbackState: PlaybackState,
        engineProgress: TimeInterval,
        sourceIsLocal: Bool,
        transitionPending: Bool
    ) -> Bool {
        guard trackMatches, !sourceIsLocal, !transitionPending else { return false }
        // Buffering and recovery belong to the current track, never initial acquisition.
        guard engineProgress.isFinite, engineProgress < 0.25 else { return false }
        return playbackState == .loading || playbackState == .playing
    }

    private func isPlaybackStillAcquiring(songID: String, epoch: UInt64) async -> Bool {
        guard epoch == playbackEpoch, let source = currentSource else { return false }
        let snapshot = await MainActor.run { (state.currentTrack?.id, state.playbackState) }
        guard epoch == playbackEpoch, !Task.isCancelled else { return false }
        return Self.shouldRecoverAcquiringPlayback(
            trackMatches: snapshot.0 == songID,
            playbackState: snapshot.1,
            engineProgress: engineProgress(),
            sourceIsLocal: source.isLocal,
            transitionPending: isTrackTransitionPending
        )
    }

    @discardableResult
    func recoverAcquiringPlaybackFromLocalMedia(
        song: DisplayableSong,
        serverId: UUID,
        expectedEpoch: UInt64?,
        reason: String
    ) async -> Bool {
        let epoch = expectedEpoch ?? playbackEpoch
        guard epoch == playbackEpoch, !Task.isCancelled else { return false }
        let localSource: MediaSource?
        if let url = await downloadService.downloadedURL(forSongId: song.id, serverId: serverId) {
            localSource = .downloaded(url)
        } else if let url = await cacheService.cachedURL(forSongId: song.id, serverId: serverId) {
            localSource = .cached(url)
        } else {
            localSource = nil
        }
        guard let localSource else { return false }
        guard epoch == playbackEpoch, !Task.isCancelled else { return false }

        let snapshot = await MainActor.run { (state.currentTrack?.id, state.playbackState) }
        guard epoch == playbackEpoch, !Task.isCancelled, let activeSource = currentSource,
              Self.shouldRecoverAcquiringPlayback(
                trackMatches: snapshot.0 == song.id,
                playbackState: snapshot.1,
                engineProgress: engineProgress(),
                sourceIsLocal: activeSource.isLocal,
                transitionPending: isTrackTransitionPending
              ) else { return false }

        Logger.player.warning("[ACQUIRE] \(reason, privacy: .public) — switching '\(song.id, privacy: .public)' to local media")
        await restartAcquiringPlayback(
            song: song,
            source: localSource,
            epoch: epoch,
            reason: reason
        )
        return true
    }

    private func restartAcquiringPlayback(
        song: DisplayableSong,
        source: MediaSource,
        epoch: UInt64,
        reason: String
    ) async {
        guard epoch == playbackEpoch else { return }
        let snapshot = await MainActor.run { (state.currentTrack?.id, state.position) }
        guard epoch == playbackEpoch, !Task.isCancelled, snapshot.0 == song.id else { return }
        let resumeAt = max(snapshot.1, engineProgress())
        let useSystemPlayer = shouldUseSystemPlayer(for: song, source: source)
            || (resumeAt >= 1 && !source.supportsTranscodeOffset)

        isTrackTransitionPending = true
        stopProgressTimer()
        cancelGaplessBridge()
        cancelPendingCacheDownload()
        stopEngine()
        guard epoch == playbackEpoch else {
            isTrackTransitionPending = false
            return
        }
        currentSource = source
        finalizePlaySegment()
        pendingRestoreInfo = useSystemPlayer ? (seekTime: resumeAt, pause: false) : nil
        // A restored AVPlayer item can report zero until its seek lands. Keep that
        // temporary clock out of the scrubber and end-of-track wrap detection.
        seekState = resumeAt > 0
            ? .settling(target: resumeAt, deadline: Date().addingTimeInterval(12)) : .idle
        lastObservedEngineProgress = resumeAt
        systemPlayback.recoveredCurrentStall = true
        await MainActor.run {
            state.position = resumeAt
            state.playbackState = resumeAt > 0 ? .recovering : .loading
            state.isDeliveringTranscodedAudio = AudioQualityClassifier.isLossyTranscodeStream(source)
        }
        isTrackTransitionPending = false
        systemPlayback.transitionRequestedAt = Date()
        Logger.player.info("[ACQUIRE] restarting '\(song.id, privacy: .public)' from \(resumeAt, format: .fixed(precision: 1))s — \(reason, privacy: .public)")
        startEnginePlayback(
            url: source.url,
            headers: source.customHeaders,
            useSystemPlayer: useSystemPlayer
        )
        startProgressTimer()
    }

    private func failPlaybackAcquisition(songID: String, epoch: UInt64) async {
        guard epoch == playbackEpoch else { return }
        let snapshot = await MainActor.run { (state.currentTrack?.id, state.position) }
        guard epoch == playbackEpoch, !Task.isCancelled, snapshot.0 == songID else { return }
        Logger.player.error("[ACQUIRE] playback timed out for '\(songID, privacy: .public)'")
        stopProgressTimer()
        stopEngine()
        if snapshot.1 > 0 { pendingRestoreInfo = (seekTime: snapshot.1, pause: false) }
        await MainActor.run { state.playbackState = .error(.timeout) }
    }

    func shouldUseSystemPlayer(for song: DisplayableSong, source: MediaSource) -> Bool {
        #if os(macOS)
        true
        #else
        if source.url.pathExtension.lowercased() == "m3u8" { return true }
        // Route according to delivered bytes. The original FLAC's unknown channel layout
        // does not turn an AAC/MP3 stereo transcode into spatial audio.
        if !AudioQualityClassifier.isLossyTranscodeStream(source),
           AudioQualityClassifier.requiresSystemPlayer(song) { return true }
        return PlayerService.isWirelessSystemRouteActive()
        #endif
    }

    func stopEngine() {
        if systemPlayback.isActive {
            tearDownSystemPlayer()
            systemPlayback.isActive = false
        }
        engine.stop()
        streamTimeOffset = 0
        Task { @MainActor in PlaybackBeatMeter.shared.setEnabled(false) }
    }

    var activeEngine: any PlaybackEngine { systemPlayback.isActive ? systemEngine : engine }

    func pauseEngine() {
        activeEngine.pause()
        Task { @MainActor in PlaybackBeatMeter.shared.setEnabled(false) }
    }
    func seekEngine(to position: TimeInterval) { activeEngine.seek(to: max(0, position - streamTimeOffset)) }
    func engineProgress() -> Double { streamTimeOffset + activeEngine.progress }
    func engineDuration() -> Double {
        let duration = activeEngine.duration
        return duration > 0 ? streamTimeOffset + duration : 0
    }
    func engineIsSeekable() -> Bool { currentSource?.supportsTranscodeOffset == true || activeEngine.isSeekable }
    func engineVolume() -> Float { activeEngine.volume }
    func setEngineVolume(_ volume: Float) { activeEngine.volume = volume }

    private func handleSystemPlayerFailure(generation: UInt64) async {
        guard systemPlayback.isActive, generation == systemPlayback.generation else { return }
        let isLive = await MainActor.run { state.isLiveStream }
        guard systemPlayback.isActive, generation == systemPlayback.generation else { return }
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
        guard systemPlayback.isActive, generation == systemPlayback.generation,
              systemEngine.observedItemID == itemID else { return }
        if systemEngine.hasQueuedItem {
            let epoch = playbackEpoch
            // End notification can precede AVQueuePlayer's current-item KVO. Give the
            // native handoff time to settle; a queued item alone is not proof of playback.
            for _ in 0..<20 {
                await handleSystemPlayerItemChanged(generation: generation)
                guard systemPlayback.isActive, generation == systemPlayback.generation,
                      epoch == playbackEpoch, systemEngine.observedItemID == itemID else { return }
                if !systemEngine.hasQueuedItem { break }
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            }
            await handleSystemPlayerItemChanged(generation: generation)
            guard !isHandlingEndOfTrack, epoch == playbackEpoch else { return }
            // Preserve an explicit user pause; resume will retain the queued item.
            let paused = await MainActor.run { state.playbackState == .paused }
            guard !paused, generation == systemPlayback.generation, epoch == playbackEpoch else { return }
            Logger.player.warning("[GAPLESS] native handoff did not complete — advancing through the regular queue")
            cancelGaplessBridge()
        }
        let liveStation = await MainActor.run { state.currentRadio?.name }
        guard systemPlayback.isActive, generation == systemPlayback.generation else { return }
        if let liveStation {
            await handleLiveStreamFailure(stationName: liveStation, error: nil)
        } else {
            await handleEndOfTrack(engineConfirmed: true)
        }
    }

    private func handleSystemPlayerTimeControlStatus(_ rawStatus: Int, generation: UInt64) async {
        guard systemPlayback.isActive, generation == systemPlayback.generation,
              let status = AVPlayer.TimeControlStatus(rawValue: rawStatus),
              systemEngine.timeControlStatus == status else { return }

        switch status {
        case .playing:
            let limited = await MainActor.run { serverService.state.isLimitedNetwork }
            guard generation == systemPlayback.generation, !isTrackTransitionPending,
                  systemEngine.timeControlStatus == .playing else { return }
            systemEngine.setForwardBuffer(PlaybackBufferPolicy.forwardBuffer(
                isLocal: currentSource?.isLocal == true, isLimited: limited
            ))
            // A state notification is not proof of output: the watchdog also observes media time.
            startSystemPlayerProgressWatchdog(generation: generation)
            if let requested = systemPlayback.transitionRequestedAt {
                systemPlayback.transitionRequestedAt = nil
                Logger.player.info(
                    "[TRANSITION-TIMING] AVPlayer audio started \(Int(Date().timeIntervalSince(requested) * 1000), privacy: .public)ms after the request"
                )
            }
            let seekable = engineIsSeekable()
            await publishEnginePlaybackConfirmation()
            await MainActor.run {
                state.isPlaybackAvailable = true
                state.isSeekable = seekable
            }
        case .waitingToPlayAtSpecifiedRate:
            // Throttled diagnostics: "no audio at all" from the AVPlayer path is almost always this
            // state, and the buffered amount tells us whether the incoming stream is simply faster than
            // the link (a hi-res lossless original on a slower connection).
            let buffered = systemEngine.bufferedDuration
            let likely = systemEngine.isLikelyToKeepUp
            if Date().timeIntervalSince(systemPlayback.lastWaitingLogAt) >= 2 {
                systemPlayback.lastWaitingLogAt = Date()
                Logger.player.warning(
                    "[AVPLAYER] waiting to play — buffered \(buffered, format: .fixed(precision: 1))s likelyToKeepUp=\(likely, privacy: .public)"
                )
            }
            startSystemPlayerProgressWatchdog(generation: generation)
            await publishEngineWaiting()
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
    /// Promotes pending audio phases only. A user pause while the stream was still opening has
    /// already written `.paused`, and a session restore that is about to pause itself must not
    /// flash the pause control on its way there.
    func publishEnginePlaybackConfirmation() async {
        let epoch = playbackEpoch
        let restoringIntoPause = pendingRestoreInfo?.pause == true
        let confirmed = await MainActor.run { () -> Bool in
            guard let promoted = state.playbackState.confirmingPlayback(
                restoringIntoPause: restoringIntoPause
            ) else { return false }
            state.playbackState = promoted
            Logger.player.debug("[PLAYER] engine confirmed playback — publishing .playing")
            return true
        }
        guard confirmed, epoch == playbackEpoch else { return }
        if currentPlaySegmentStart == nil { currentPlaySegmentStart = Date() }
    }

    func publishEngineWaiting() async {
        let epoch = playbackEpoch
        let waiting = await MainActor.run { () -> Bool in
            guard let pending = state.playbackState.waitingForAudio() else { return false }
            state.playbackState = pending
            return true
        }
        guard waiting, epoch == playbackEpoch else { return }
        finalizePlaySegment()
    }

    /// Reopening a current track is recovery, even when the reason is an output-route change.
    func publishEngineRecovery() async -> Bool {
        let epoch = playbackEpoch
        let recovering = await MainActor.run { () -> Bool in
            guard state.playbackState.hasPlaybackIntent else { return false }
            state.playbackState = state.playbackState.resuming(reopensSource: true, position: state.position)
            return true
        }
        guard recovering, epoch == playbackEpoch, !Task.isCancelled else { return false }
        finalizePlaySegment()
        return true
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
