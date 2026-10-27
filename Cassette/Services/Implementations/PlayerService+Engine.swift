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
        useSystemPlayer: Bool,
        reusingSystemPlayer: Bool = false,
        isLimitedNetwork: Bool = true,
        initialVolume: Float? = nil
    ) {
        guard !transport.interrupted else { return }
        Logger.player.notice("[ENGINE-START] epoch=\(self.playbackEpoch) requestedNative=\(useSystemPlayer) reuseNative=\(reusingSystemPlayer) restore=\(self.pendingRestoreInfo?.seekTime ?? 0, format: .fixed(precision: 2))s")
        let restoreInfo = pendingRestoreInfo
        let transcodeRequest = currentSource?.isJellyfinUniversal == true && restoreInfo == nil
            ? nil : currentSource?.transcodeRequest(at: restoreInfo?.seekTime ?? 0)
        let requestURL = transcodeRequest?.url ?? url
        streamTimeOffset = transcodeRequest?.offset ?? 0
        #if os(macOS)
        let useAVPlayer = true
        #else
        // A progressive transcode has no stable byte ranges. AudioStreaming probes/retries
        // those ranges and can reopen a truncated AAC response after successive scrubs.
        // Native playback owns offset responses and fences callbacks per new item.
        let useAVPlayer = useSystemPlayer || currentSource?.supportsTranscodeOffset == true
        #endif

        if useAVPlayer {
            engine.stop()
            if reusingSystemPlayer, systemPlayback.isActive {
                cancelGaplessBridge()
                systemPlayback.invalidateCallbacks()
                stopSystemPlayerProgressWatchdog()
            } else {
                tearDownSystemPlayer()
            }
            systemPlayback.isActive = true
            Task { @MainActor in PlaybackBeatMeter.shared.setEnabled(true) }

            #if os(iOS)
            // Re-assert multichannel / Spatial Audio session before AVPlayer starts decoding.
            configureAudioSessionIfNeeded(preferMultichannel: true)
            #endif

            pendingRestoreInfo = nil
            if restoreInfo != nil { isRestoringSession = false }
            if let restoreInfo, restoreInfo.seekTime > 0 {
                seekState = .settling(target: restoreInfo.seekTime, deadline: Date().addingTimeInterval(12))
                lastObservedEngineProgress = restoreInfo.seekTime
            }
            systemEngine.volume = (initialVolume ?? restoredVolume) * nativeGainMultiplier
            systemEngine.start(url: requestURL, headers: headers, generation: systemPlayback.generation,
                               position: transcodeRequest == nil ? (restoreInfo?.seekTime ?? 0) : 0,
                               paused: restoreInfo?.pause ?? false, reusingPlayer: reusingSystemPlayer,
                               allowsAudioAnalysis: !gaplessEnabled || currentSource?.isLiveStream == true,
                               promptStartupBuffer: currentSource?.isLocal == false && currentSource?.isLiveStream == false
                                   && currentSource?.url.pathExtension.lowercased() != "m3u8"
                                   ? PlaybackBufferPolicy.startupBuffer(isLimited: isLimitedNetwork) : nil)
            logSpatialRouteStatus()
        } else {
            #if !os(macOS)
            // macOS always routes through AVPlayer (`useAVPlayer` is constant `true`),
            // so this branch only exists on iOS.
            tearDownSystemPlayer()
            systemPlayback.isActive = false
            engine.volume = initialVolume ?? restoredVolume
            if transcodeRequest != nil {
                pendingRestoreInfo = restoreInfo?.pause == true ? (seekTime: 0, pause: true) : nil
            }
            engine.play(url: requestURL, headers: headers)
            if restoreInfo?.pause == true, transcodeRequest != nil { engine.pause() }
            Task { @MainActor in PlaybackBeatMeter.shared.setEnabled(true) }
            #endif
        }
    }

    func handleSystemEngineEvent(_ event: AVPlayerPlaybackEngine.Event, expectedContext: PlaybackContext? = nil) async {
        guard expectedContext == nil || expectedContext == playbackContext else { return }
        switch event {
        case .itemChanged(let generation): await handleSystemPlayerItemChanged(generation: generation)
        case .ended(let generation, let itemID): await handleSystemPlayerDidReachEnd(generation: generation, itemID: itemID)
        case .failed(let generation, let itemID, let failure):
            guard systemEngine.observedItemID == itemID else { return }
            await handleSystemPlayerFailure(generation: generation, failure: failure)
        case .timeControl(let generation, let status): await handleSystemPlayerTimeControlStatus(status, generation: generation)
        case .seekFailed(let generation, let itemID, let sequence):
            guard generation == systemPlayback.generation, systemEngine.observedItemID == itemID,
                  sequence == systemEngine.seekSequenceNumber, let target = seekState.target else { return }
            await recoverFailedSeek(target: target, failedGeneration: generation)
        case .codec(let generation, let itemID, let codec):
            guard generation == systemPlayback.generation, systemEngine.observedItemID == itemID else { return }
            // Codec describes the decoded bytes, not whether the server transformed them.
            let isTranscoded = currentSource.map(AudioQualityClassifier.isLossyTranscodeStream) ?? false
            await MainActor.run {
                guard systemEngine.observedItemID == itemID else { return }
                state.isDeliveringTranscodedAudio = isTranscoded
            }
            _ = codec
        case .stalled(let generation):
            guard generation == systemPlayback.generation, !systemPlayback.recoveredCurrentStall,
                  seekState == .idle, Date() >= systemPlayback.seekSettleDeadline else { return }
            await recoverFromStalledStream()
        }
    }

    func handleSystemPlayerItemChanged(generation: UInt64) async {
        guard generation == systemPlayback.generation, systemPlayback.isActive,
              !hasPendingSelection, !isHandlingEndOfTrack, systemEngine.consumeQueuedTransition() else { return }
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

    func recoverUnexpectedStreamReset(position: Double) async {
        let epoch = playbackEpoch
        let commandID = transportCommandID
        let request = seekRequestGeneration
        guard let source = currentSource else { return }
        let snapshot = await MainActor.run { (state.currentTrack, state.playbackState) }
        guard epoch == playbackEpoch, commandID == transportCommandID, request == seekRequestGeneration,
              snapshot.1.hasPlaybackIntent, let song = snapshot.0 else { return }
        if systemPlayback.recoveredCurrentStall {
            await finishPlaybackFailure(.timeout, context: playbackContext, position: position)
            return
        }
        systemPlayback.recoveredCurrentStall = true
        await restartAcquiringPlayback(song: song, source: source, epoch: epoch,
                                       reason: "unexpected stream end or clock reset", resumePosition: position)
        guard epoch == playbackEpoch, commandID == transportCommandID else { return }
        scheduleStallRecoveryCompletion(songID: song.id, epoch: epoch, position: position)
    }

    /// Retry once after a sustained stall, retaining the current item while resolving its replacement.
    func recoverFromStalledStream() async {
        let epoch = playbackEpoch
        let generation = systemPlayback.generation
        let command = transportCommandID
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
            reason: "stream stalled",
            phase: .stalled
        ) {
            guard epoch == playbackEpoch, command == transportCommandID else { return }
            scheduleStallRecoveryCompletion(songID: song.id, epoch: epoch, position: stalledProgress)
            return
        }
        guard epoch == playbackEpoch, command == transportCommandID, !Task.isCancelled else { return }
        // Never destroy an explicit lossless/bitstream request to hide a slow connection. The
        // playback method is always automatic now, so only the quality choice can block the step-down.
        systemPlayback.lastStallRecoveryAt = Date()
        if context.2 == .matchStream, !AudioQualityClassifier.shouldSkipTranscoding(source.playbackSong ?? song),
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
                  command == transportCommandID, !Task.isCancelled, !isTrackTransitionPending, seekState == .idle,
                  Date() >= systemPlayback.seekSettleDeadline,
                  playbackState.hasPlaybackIntent,
                  engineProgress() <= stalledProgress + 0.1 else { return }
            await restartAcquiringPlayback(song: song, source: refreshed, epoch: epoch,
                                           reason: "sustained playback stall")
            scheduleStallRecoveryCompletion(songID: song.id, epoch: epoch, position: stalledProgress)
        } catch {
            guard epoch == playbackEpoch, command == transportCommandID,
                  generation == systemPlayback.generation, !Task.isCancelled else { return }
            let stillIntendsPlayback = await MainActor.run { state.playbackState.hasPlaybackIntent }
            guard epoch == playbackEpoch, command == transportCommandID, stillIntendsPlayback,
                  engineProgress() <= stalledProgress + 0.1 else { return }
            Logger.player.error("[STALL] source refresh failed: \(error, privacy: .public)")
            await finishPlaybackFailure(.playbackFailed(.classify(error)), context: playbackContext, position: stalledProgress)
        }
    }

    func scheduleStallRecoveryCompletion(songID: String, epoch: UInt64, position: Double) {
        let context = playbackContext
        playbackAcquisitionTask?.cancel()
        playbackAcquisitionTask = Task { [weak self] in
            guard let self else { return }
            for _ in 0..<30 {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard await self.contextIsCurrent(context) else { return }
                let snapshot = await MainActor.run { (self.state.currentTrack?.id, self.state.playbackState) }
                guard await self.contextIsCurrent(context), snapshot.0 == songID,
                      snapshot.1.hasPlaybackIntent else { return }
                if await self.engineProgress() > position + 0.25 { return }
            }
            guard await self.contextIsCurrent(context) else { return }
            await self.failPlaybackAcquisition(songID: songID, epoch: epoch)
        }
    }

    /// A finite stream must not remain in acquisition forever. First prefer a completed download
    /// or cache entry; if neither exists after the initial window, refresh the source once. The
    /// epoch and track id fence every suspension so a late recovery cannot replace a newer song.
    func schedulePlaybackAcquisitionRecovery(song: DisplayableSong, serverId: UUID, epoch: UInt64) {
        guard epoch == playbackEpoch else { return }
        let context = playbackContext
        if currentSource?.isLocal == true {
            scheduleStallRecoveryCompletion(songID: song.id, epoch: epoch, position: engineProgress())
            return
        }
        playbackAcquisitionTask?.cancel()
        playbackAcquisitionTask = Task { [weak self] in
            guard let self else { return }
            let deadline = await self.makePlaybackStartWatchdog(context: context, songID: song.id)
            defer { deadline.cancel() }
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
                    await self.scheduleStallRecoveryCompletion(songID: song.id, epoch: epoch, position: 0)
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
                    await self.scheduleStallRecoveryCompletion(songID: song.id, epoch: epoch, position: 0)
                    return
                }
            }
            guard await self.isPlaybackStillAcquiring(songID: song.id, epoch: epoch) else { return }
            await self.failPlaybackAcquisition(songID: song.id, epoch: epoch)
        }
    }

    /// Independent of source resolution: a hung refresh must not hold the startup
    /// deadline hostage. Late work is fenced by the transport command and cancellation.
    func makePlaybackStartWatchdog(context: PlaybackContext, songID: String,
                                   timeout: Duration = .seconds(45)) -> Task<Void, Never> {
        Task { [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            await self?.expirePlaybackStart(context: context, songID: songID)
        }
    }

    private func expirePlaybackStart(context: PlaybackContext, songID: String) async {
        guard contextIsCurrent(context), transport.permitsAudio, currentSource?.isLiveStream != true else { return }
        let snapshot = await MainActor.run { (state.currentTrack?.id, state.playbackState) }
        guard contextIsCurrent(context), snapshot.0 == songID, snapshot.1.hasPlaybackIntent,
              engineProgress() < 0.25 else { return }
        if await recoverFailedCachedPlayback(context: context) { return }
        guard contextIsCurrent(context) else { return }
        Logger.player.error("[ACQUIRE] no media progress before startup deadline")
        await finishPlaybackFailure(.timeout, context: context, position: 0)
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
        // Engine callbacks can report playing then waiting before the first sample.
        // All pending playback phases must remain covered while the clock is at zero.
        guard engineProgress.isFinite, engineProgress >= 0, engineProgress < 0.25 else { return false }
        return playbackState.hasPlaybackIntent
    }

    nonisolated enum LocalPlaybackRecoveryPhase: Sendable { case acquiring, stalled }

    nonisolated static func shouldRecoverFromLocalMedia(
        phase: LocalPlaybackRecoveryPhase, trackMatches: Bool, playbackState: PlaybackState,
        engineProgress: TimeInterval, sourceIsLocal: Bool, transitionPending: Bool
    ) -> Bool {
        switch phase {
        case .acquiring:
            return shouldRecoverAcquiringPlayback(trackMatches: trackMatches, playbackState: playbackState,
                engineProgress: engineProgress, sourceIsLocal: sourceIsLocal, transitionPending: transitionPending)
        case .stalled:
            return trackMatches && !sourceIsLocal && !transitionPending
                && engineProgress.isFinite && engineProgress >= 0.25 && playbackState.hasPlaybackIntent
        }
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
        reason: String,
        phase: LocalPlaybackRecoveryPhase = .acquiring
    ) async -> Bool {
        let epoch = expectedEpoch ?? playbackEpoch
        let command = transportCommandID
        let generation = systemPlayback.generation
        guard epoch == playbackEpoch, !Task.isCancelled else { return false }
        let localSource: MediaSource?
        let actualSong = currentSource?.playbackSong
        let selectedID = actualSong?.id ?? song.id
        let selectedURL = actualSong.map(AtmosVariantCatalogue.isAtmos) == true
            ? await downloadService.downloadedOriginalURL(forSongId: selectedID, serverId: serverId)
            : await downloadService.downloadedURL(forSongId: selectedID, serverId: serverId)
        if let url = selectedURL {
            localSource = .downloaded(url, playbackSong: actualSong)
        } else if selectedID != song.id, let url = await downloadService.downloadedURL(forSongId: song.id, serverId: serverId) {
            localSource = .downloaded(url)
        } else if actualSong == nil, !AtmosVariantCatalogue.isAtmos(song),
                  let url = await cacheService.cachedURL(forSongId: song.id, serverId: serverId) {
            localSource = .cached(url)
        } else {
            localSource = nil
        }
        guard let localSource else { return false }
        guard epoch == playbackEpoch, !Task.isCancelled else { return false }

        let snapshot = await MainActor.run { (state.currentTrack?.id, state.playbackState) }
        guard epoch == playbackEpoch, command == transportCommandID,
              generation == systemPlayback.generation, !Task.isCancelled, let activeSource = currentSource,
              Self.shouldRecoverFromLocalMedia(
                phase: phase,
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
        reason: String,
        resumePosition: TimeInterval? = nil
    ) async {
        guard epoch == playbackEpoch else { return }
        let commandID = transportCommandID
        let snapshot = await MainActor.run { (state.currentTrack?.id, state.position) }
        guard epoch == playbackEpoch, commandID == transportCommandID,
              !Task.isCancelled, snapshot.0 == song.id else { return }
        let resumeAt = max(snapshot.1, engineProgress(), resumePosition ?? 0)
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
        pendingRestoreInfo = (useSystemPlayer || source.supportsTranscodeOffset)
            ? (seekTime: resumeAt, pause: false) : nil
        // A restored AVPlayer item can report zero until its seek lands. Keep that
        // temporary clock out of the scrubber and end-of-track wrap detection.
        seekState = resumeAt > 0
            ? .settling(target: resumeAt, deadline: Date().addingTimeInterval(12)) : .idle
        lastObservedEngineProgress = resumeAt
        systemPlayback.recoveredCurrentStall = true
        guard await commitPresentation(PlaybackContext(command: commandID, epoch: epoch), { state in
            state.position = resumeAt
            state.playbackState = resumeAt > 0 ? .recovering : .loading
            state.isDeliveringTranscodedAudio = AudioQualityClassifier.isLossyTranscodeStream(source)
            state.currentPlaybackTrack = source.playbackSong
            return true
        }) else { return }
        // stopProgressTimer can cancel the task that detected this reset. New transport
        // commands/epochs still win, but that intentional cancellation must not strand recovery.
        guard epoch == playbackEpoch, commandID == transportCommandID else { return }
        let replayGainConfig = await MainActor.run { replayGainSettings.config }
        guard epoch == playbackEpoch, commandID == transportCommandID else { return }
        await applyReplayGain(track: source.playbackSong ?? song, config: replayGainConfig,
                              context: PlaybackContext(command: commandID, epoch: epoch))
        guard epoch == playbackEpoch, commandID == transportCommandID else { return }
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
        let context = playbackContext
        let snapshot = await MainActor.run { (state.currentTrack?.id, state.position) }
        guard contextIsCurrent(context), snapshot.0 == songID else { return }
        if await recoverFailedCachedPlayback(context: context) { return }
        guard contextIsCurrent(context) else { return }
        Logger.player.error("[ACQUIRE] playback timed out for '\(songID, privacy: .public)'")
        await finishPlaybackFailure(.timeout, context: playbackContext, position: snapshot.1)
    }

    /// Evict only a failed transient entry, then resolve once without selecting it again.
    /// Downloads remain pinned. Context checks prevent a late failure replacing a newer song.
    func recoverFailedCachedPlayback(context: PlaybackContext) async -> Bool {
        guard contextIsCurrent(context), transport.terminalContext != context,
              let failedSource = currentSource, case .cached = failedSource else { return false }
        let actualTrack = failedSource.playbackSong
        let snapshot = await MainActor.run { (state.currentTrack, serverService.state.activeServer?.id,
                                              state.playbackState.hasPlaybackIntent, state.position) }
        guard contextIsCurrent(context), snapshot.2, let song = snapshot.0, let server = snapshot.1 else { return false }
        await cacheService.invalidate(songId: actualTrack?.id ?? song.id, serverId: server, matching: failedSource.url)
        guard contextIsCurrent(context) else { return true }
        guard !systemPlayback.recoveredCurrentStall else { return false }
        systemPlayback.recoveredCurrentStall = true
        Logger.player.notice("[LOCAL-AUDIO] cached playback failed; evicted entry and resolving replacement")
        let deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            await self?.expireCachedRecovery(context: context, songID: song.id, position: snapshot.3)
        }
        defer { deadline.cancel() }
        do {
            let source = try await mediaResolver.resolve(songId: song.id, serverId: server, song: song)
            guard contextIsCurrent(context), transport.terminalContext != context else { return true }
            await restartAcquiringPlayback(song: song, source: source, epoch: context.epoch,
                                           reason: "invalid cached audio", resumePosition: snapshot.3)
            guard contextIsCurrent(context) else { return true }
            scheduleStallRecoveryCompletion(songID: song.id, epoch: context.epoch, position: snapshot.3)
        } catch {
            guard contextIsCurrent(context) else { return true }
            await finishPlaybackFailure(.playbackFailed(.classify(error)), context: context, position: snapshot.3)
        }
        return true
    }

    private func expireCachedRecovery(context: PlaybackContext, songID: String, position: Double) async {
        guard contextIsCurrent(context), case .cached = currentSource else { return }
        let snapshot = await MainActor.run { (state.currentTrack?.id, state.playbackState.hasPlaybackIntent) }
        guard contextIsCurrent(context), snapshot.0 == songID, snapshot.1 else { return }
        await finishPlaybackFailure(.timeout, context: context, position: position)
    }

    func shouldUseSystemPlayer(for song: DisplayableSong, source: MediaSource) -> Bool {
        #if os(macOS)
        true
        #else
        // Cached MP4 may have moov at the end; native local playback does not require
        // the streaming parser's faststart layout and can probe the actual container.
        if case .cached = source { return true }
        if source.supportsTranscodeOffset { return true }
        if source.url.pathExtension.lowercased() == "m3u8" { return true }
        if !source.isLocal, AudioQualityClassifier.isLossyTranscodeStream(source) { return true }
        // Route according to delivered bytes. The original FLAC's unknown channel layout
        // does not turn an AAC/MP3 stereo transcode into spatial audio.
        if !AudioQualityClassifier.isLossyTranscodeStream(source),
           AudioQualityClassifier.requiresSystemPlayer(source.playbackSong ?? song) { return true }
        return PlayerService.isWirelessSystemRouteActive()
        #endif
    }

    func stopEngine() {
        seekCommitTask?.cancel()
        seekCommitTask = nil
        seekSettlementTask?.cancel()
        seekSettlementTask = nil
        seekDownloadTask?.cancel()
        seekDownloadTask = nil
        seekRecoveryRequest = nil
        seekRecoveryInFlight = nil
        if systemPlayback.isActive {
            tearDownSystemPlayer()
            systemPlayback.isActive = false
        }
        engine.stop()
        if let url = seekBufferURL { try? FileManager.default.removeItem(at: url) }
        seekBufferURL = nil
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
    func engineIsSeekable() -> Bool {
        currentSource.map { !$0.isLocal && !$0.isLiveStream } == true || activeEngine.isSeekable
    }
    func engineVolume() -> Float {
        systemPlayback.isActive ? systemEngine.volume / nativeGainMultiplier : engine.volume
    }
    func setEngineVolume(_ volume: Float) {
        activeEngine.volume = max(0, min(1, volume)) * (systemPlayback.isActive ? nativeGainMultiplier : 1)
    }

    var engineCapabilities: EngineCapabilities {
        #if os(iOS)
        EngineCapabilities(native: systemPlayback.isActive, wirelessRoute: Self.isWirelessSystemRouteActive())
        #else
        EngineCapabilities(native: systemPlayback.isActive, wirelessRoute: false)
        #endif
    }

    func applyReplayGain(track: DisplayableSong?, config: ReplayGainConfig, context: PlaybackContext) async {
        guard context == playbackContext else { return }
        let baseVolume = engineVolume()
        playbackGain = ReplayGainService.gainState(track: track, config: config)
        nativeGainMultiplier = EngineCapabilities(native: true, wirelessRoute: false)
            .nativeGainMultiplier(requested: playbackGain.requestedDB)
        if systemPlayback.isActive { setEngineVolume(baseVolume) }
        await replayGainService?.apply(gainDB: playbackGain.requestedDB, authority: authority, context: context)
    }

    private func handleSystemPlayerFailure(generation: UInt64, failure: PlaybackFailure) async {
        let context = playbackContext
        guard systemPlayback.isActive, generation == systemPlayback.generation else { return }
        let isLive = await MainActor.run { state.isLiveStream }
        guard contextIsCurrent(context), systemPlayback.isActive, generation == systemPlayback.generation else { return }
        if isLive {
            let name = await MainActor.run { state.currentRadio?.name ?? "" }
            await handleLiveStreamFailure(stationName: name, error: nil)
        } else {
            guard failure.kind != .cancelled else { return }
            if await recoverFailedCachedPlayback(context: context) { return }
            guard contextIsCurrent(context) else { return }
            if failure.kind == .network || failure.kind == .unknown, let target = seekState.target {
                await recoverFailedSeek(target: target, failedGeneration: generation)
                return
            }
            let epoch = playbackEpoch
            let commandID = transportCommandID
            let snapshot = await MainActor.run {
                (state.currentTrack, state.position, state.playbackState,
                 serverService.state.activeServer?.id)
            }
            guard generation == systemPlayback.generation, epoch == playbackEpoch,
                  commandID == transportCommandID else { return }
            let position = max(snapshot.1, engineProgress())
            // A failed item cannot be resumed. Refresh once, preserving the last audible
            // position; a repeated failure ends with a retryable error instead of looping.
            let decision = PlaybackRecoveryPolicy.decide(failure,
                permitsAudio: transport.permitsAudio && snapshot.2.hasPlaybackIntent,
                attempted: systemPlayback.recoveredCurrentStall,
                canRefresh: currentSource?.isLocal == false || currentSource?.playbackSong != nil,
                canFallBackToOriginal: currentSource?.playbackSong?.id != nil && currentSource?.playbackSong?.id != snapshot.0?.id)
            if decision == .refreshSource, let song = snapshot.0, let serverID = snapshot.3 {
                systemPlayback.recoveredCurrentStall = true
                do {
                    let source: MediaSource
                    if currentSource?.playbackSong?.id != nil, currentSource?.playbackSong?.id != song.id {
                        source = try await mediaResolver.resolveOriginal(songId: song.id, serverId: serverID, song: song)
                    } else {
                        source = try await mediaResolver.resolve(songId: song.id, serverId: serverID, song: song)
                    }
                    guard generation == systemPlayback.generation, epoch == playbackEpoch,
                          commandID == transportCommandID, !Task.isCancelled else { return }
                    await restartAcquiringPlayback(song: song, source: source, epoch: epoch,
                                                   reason: "failed native item")
                    guard epoch == playbackEpoch, commandID == transportCommandID else { return }
                    scheduleStallRecoveryCompletion(songID: song.id, epoch: epoch, position: position)
                    return
                } catch {
                    guard generation == systemPlayback.generation, epoch == playbackEpoch,
                          commandID == transportCommandID, !Task.isCancelled else { return }
                }
            }
            await finishPlaybackFailure(.playbackFailed(failure), context: PlaybackContext(command: commandID, epoch: epoch), position: position)
        }
    }

    private func handleSystemPlayerDidReachEnd(generation: UInt64, itemID: ObjectIdentifier) async {
        guard systemPlayback.isActive, generation == systemPlayback.generation,
              systemEngine.observedItemID == itemID else { return }
        if let target = seekState.target, !systemEngine.isSeeking, !systemEngine.lastSeekFailed {
            let end = await MainActor.run { (state.duration, state.playbackState.hasPlaybackIntent) }
            guard generation == systemPlayback.generation, systemEngine.observedItemID == itemID else { return }
            if end.1, end.0 > 0, target >= end.0 - 1 {
                seekState = .idle
                seekNeedsCommit = false
                systemPlayback.seekSettleDeadline = .distantPast
                seekSettlementTask?.cancel()
                seekSettlementTask = nil
                await MainActor.run {
                    state.position = end.0
                    state.pendingSeekPosition = nil
                }
            }
        }
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
            cancelPendingCacheDownload()
            cancelPendingPrefetch()
            if engineProgress() > 0.25 {
                cancelGaplessBridge()
                nextGaplessPreparationAttempt = Date().addingTimeInterval(5)
            }
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
    func publishEnginePlaybackConfirmation(settledPosition: TimeInterval? = nil, confirmsPlayback: Bool = true) async {
        // A pre-seek .playing callback is not proof that the requested clock has landed.
        // The settlement monitor promotes playback after confirming the latest target.
        guard seekState == .idle, transport.permitsAudio, !isTrackTransitionPending else { return }
        // A seek or buffered clock jump while waiting is not audible playback.
        let confirmsPlayback = confirmsPlayback && activeEngine.state == .playing
        let context = playbackContext
        let restoringIntoPause = pendingRestoreInfo?.pause == true
        let confirmed = await commitPresentation(context) { state in
            guard !Task.isCancelled else { return false }
            if let settledPosition {
                state.position = min(settledPosition, state.duration)
                state.pendingSeekPosition = nil
            } else if state.pendingSeekPosition != nil {
                return false
            }
            guard confirmsPlayback else { return false }
            guard let promoted = state.playbackState.confirmingPlayback(
                restoringIntoPause: restoringIntoPause
            ) else { return false }
            state.playbackState = promoted
            Logger.player.debug("[PLAYER] engine confirmed playback — publishing .playing")
            return true
        }
        guard confirmed, context == playbackContext, transport.permitsAudio else { return }
        RuntimeDiagnostics.mark(.playbackReady)
        Logger.player.notice("[PLAYBACK] run=\(RuntimeDiagnostics.sessionID, privacy: .public) event=confirmed epoch=\(self.playbackEpoch, privacy: .public) engine=\(self.systemPlayback.isActive ? "AVPlayer" : "AudioStreaming", privacy: .public) position_s=\(self.engineProgress(), format: .fixed(precision: 2), privacy: .public)")
        // Buffer acquisition is not audible time: start the ramp only after confirmation.
        if let duration = pendingFadeInDuration {
            pendingFadeInDuration = nil
            if engineCapabilities.supportsSequentialFades { performFadeIn(duration: duration) }
            else { setEngineVolume(restoredVolume) }
        }
        if currentPlaySegmentStart == nil { currentPlaySegmentStart = Date() }
        await pushPositionSnapshot()
        guard context == playbackContext else { return }
        await publishWidgetStatus()
        guard context == playbackContext else { return }
        await ensureGaplessPreparation()
    }

    func publishEngineWaiting() async {
        guard transport.permitsAudio else { return }
        let context = playbackContext
        let epoch = playbackEpoch
        let buffered = systemPlayback.isActive ? systemEngine.bufferedDuration : -1
        let waiting = await commitPresentation(context) { state in
            guard let pending = state.playbackState.waitingForAudio() else { return false }
            if state.playbackState == .playing {
                Logger.player.notice("[PLAYBACK] run=\(RuntimeDiagnostics.sessionID, privacy: .public) event=waiting epoch=\(epoch, privacy: .public) position_s=\(state.position, format: .fixed(precision: 2), privacy: .public) avplayer_buffered_s=\(buffered, format: .fixed(precision: 2), privacy: .public)")
            }
            state.playbackState = pending
            return true
        }
        guard waiting, context == playbackContext else { return }
        finalizePlaySegment()
        await pushPositionSnapshot(rate: 0)
        guard context == playbackContext else { return }
        await publishWidgetStatus()
    }

    /// Reopening a current track is recovery, even when the reason is an output-route change.
    func publishEngineRecovery() async -> Bool {
        guard transport.permitsAudio else { return false }
        let context = playbackContext
        let recovering = await commitPresentation(context) { state in
            guard state.playbackState.hasPlaybackIntent else { return false }
            state.playbackState = state.playbackState.resuming(reopensSource: true, position: state.position)
            return true
        }
        guard recovering, contextIsCurrent(context) else { return false }
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
