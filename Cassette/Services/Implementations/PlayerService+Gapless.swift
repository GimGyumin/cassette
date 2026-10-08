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
    // MARK: - Gapless pre-queue

    /// Hands the AudioStreaming engine the next queue entry ahead of time so it pre-buffers and
    /// transitions without a gap. When a bridge is armed, `handleEndOfTrack` advances app state
    /// instead of re-creating the engine.
    ///
    /// The *decision* lives in `GaplessPolicy` (user setting, crossfade arbitration, metered
    /// network, multichannel routing, device budget); this method only carries it out.
    func ensureGaplessPreparation() async {
        guard gaplessEnabled, !isTrackTransitionPending, !isHandlingEndOfTrack,
              seekState == .idle,
              gaplessBridge.next == nil, gaplessPreparationTask == nil,
              Date() >= nextGaplessPreparationAttempt else { return }
        nextGaplessPreparationAttempt = Date().addingTimeInterval(5)
        let epoch = playbackEpoch
        let context = await MainActor.run { (state.currentTrack, serverService.state.activeServer?.id,
                                             state.repeatMode, state.currentIndex, state.queue.count) }
        guard epoch == playbackEpoch, gaplessPreparationTask == nil,
              context.2 != .one, context.3 + 1 < context.4,
              let song = context.0, let serverId = context.1 else { return }
        gaplessPreparationGeneration &+= 1
        let preparation = gaplessPreparationGeneration
        gaplessPreparationTask = Task { [weak self] in
            guard let self else { return }
            await self.prepareGaplessWhenPlaying(current: song, serverId: serverId, epoch: epoch)
            await self.finishGaplessPreparation(generation: preparation)
        }
    }

    private func finishGaplessPreparation(generation: UInt64) {
        if generation == gaplessPreparationGeneration { gaplessPreparationTask = nil }
    }

    private func prepareGaplessWhenPlaying(current: DisplayableSong, serverId: UUID, epoch: UInt64) async {
        // Foreground audio gets the connection first. A cold server may need several seconds
        // before the engine is actually playing; don't race it with next-track resolution.
        for _ in 0..<10 {
            guard epoch == playbackEpoch, !Task.isCancelled else { return }
            let isPlaying = systemPlayback.isActive
                ? systemEngine.state == .playing : engine.state == .playing
            if isPlaying {
                await scheduleGaplessPreQueue(current: current, serverId: serverId, epoch: epoch)
                return
            }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
        }
    }

    func scheduleGaplessPreQueue(current: DisplayableSong, serverId: UUID, epoch: UInt64) async {
        guard epoch == playbackEpoch, !Task.isCancelled else { return }
        guard gaplessBridge.next == nil else { return }
        let systemGeneration = systemPlayback.generation
        let preparationGeneration = gaplessPreparationGeneration
        let (queue, currentIndex, repeatMode) = await MainActor.run { (state.queue, state.currentIndex, state.repeatMode) }
        guard repeatMode != .one else { return }
        let nextIndex = currentIndex + 1
        guard queue.indices.contains(nextIndex) else { return }
        let next = queue[nextIndex]

        let isLimited = await MainActor.run { serverService.state.isLimitedNetwork }
        // Buffering one already-selected next song is continuous playback, not an offline
        // cache download. The active network's streaming-quality preference still applies.
        let allowCellular = true
        let isAlbumPair = GaplessPolicy.isAlbumPair(
            currentAlbumId: current.albumId,
            currentTrackNumber: current.trackNumber,
            nextAlbumId: next.albumId,
            nextTrackNumber: next.trackNumber
        )
        // A multichannel / Atmos next track must not be handed to the gapless AudioStreaming
        // bridge — AudioStreaming hardcodes a stereo output and would silently downmix surround
        // beds / Atmos to stereo. Skipping the bridge lets end-of-track fall through to play(),
        // which re-routes the track through AVPlayer and preserves multichannel.
        let requiresSystemPlayer = !systemPlayback.isActive && AudioQualityClassifier.requiresSystemPlayer(next)

        func decision(nextSourceIsLocal: Bool, allowMeteredNetwork: Bool) -> GaplessDecision {
            GaplessPolicy.decision(
                hasNextTrack: true,
                crossfadeDuration: crossfadeConfig.duration,
                crossfadeDisabledForAlbumPairs: crossfadeConfig.disableForGapless,
                isAlbumPair: isAlbumPair,
                requiresSystemPlayer: requiresSystemPlayer,
                gaplessEnabled: gaplessEnabled,
                isMeteredNetwork: isLimited,
                nextSourceIsLocal: nextSourceIsLocal,
                allowMeteredNetwork: allowMeteredNetwork,
                deviceAllowsPrebuffer: CassettePerformance.allowsGaplessPrebuffer
            )
        }

        // Resolving the next source can reach the network (Jellyfin `playbackInfo`), so the
        // preflight treats a metered network as permitted: the resolve below then only happens for
        // a transition that is going to bridge anyway.
        let preflight = decision(nextSourceIsLocal: false, allowMeteredNetwork: true)
        guard preflight == .bridge else {
            logGaplessSkip(next, reason: preflight)
            return
        }

        guard let nextSource = try? await mediaResolver.resolve(songId: next.id, serverId: serverId, song: next) else {
            return
        }
        let resolved = decision(nextSourceIsLocal: nextSource.isLocal, allowMeteredNetwork: allowCellular)
        guard resolved == .bridge else {
            logGaplessSkip(next, reason: resolved)
            return
        }

        guard epoch == playbackEpoch, !Task.isCancelled,
              systemGeneration == systemPlayback.generation,
              systemPlayback.isActive || nextSource.url.pathExtension.lowercased() != "m3u8" else { return }
        let nextIsStillQueued = await MainActor.run {
            state.repeatMode != .one && state.queue.indices.contains(state.currentIndex + 1)
                && state.queue[state.currentIndex + 1].id == next.id
        }
        guard nextIsStillQueued, epoch == playbackEpoch, !Task.isCancelled,
              gaplessBridge.next == nil, preparationGeneration == gaplessPreparationGeneration else { return }
        gaplessBridge.arm(next: next, source: nextSource, epoch: epoch)
        if systemPlayback.isActive {
            guard systemEngine.prepareNext(url: nextSource.url, headers: nextSource.customHeaders) else {
                cancelGaplessBridge()
                return
            }
        } else {
            engine.queue(url: nextSource.url, headers: nextSource.customHeaders)
        }
        Logger.player.info("[GAPLESS] pre-queued '\(next.title, privacy: .public)' for seamless transition")
    }

    /// One debug line per skipped transition: "why did I hear a gap?" is answered from a device log.
    private func logGaplessSkip(_ next: DisplayableSong, reason: GaplessDecision) {
        Logger.player.debug(
            "[GAPLESS] '\(next.title, privacy: .public)' not pre-queued — \(reason.rawValue, privacy: .public)"
        )
    }

    // MARK: - End of track

    /// Reuse AVQueuePlayer's native prepared item for an explicit next-track request.
    /// Claim the transition before emitting engine events so EOF and manual next cannot both pop.
    func advancePreparedSystemTrack(tracks: [DisplayableSong], startIndex: Int) async -> Bool {
        guard systemPlayback.isActive, progressTask != nil, !isRestoringSession,
              !isTrackTransitionPending, !isHandlingEndOfTrack,
              gaplessBridge.epoch == playbackEpoch, let next = gaplessBridge.next,
              let source = gaplessBridge.source, tracks.indices.contains(startIndex),
              tracks[startIndex].id == next.id else { return false }
        let epoch = playbackEpoch
        let requestID = playbackRequestID
        let matches = await MainActor.run {
            state.playbackState == .playing && startIndex == state.currentIndex + 1
                && tracks.map(\.id) == state.queue.map(\.id)
        }
        guard matches, epoch == playbackEpoch, requestID == playbackRequestID, !Task.isCancelled,
              !isHandlingEndOfTrack, !isTrackTransitionPending else { return false }
        isHandlingEndOfTrack = true
        defer { isHandlingEndOfTrack = false }
        guard systemEngine.advanceToPreparedNext(expectedURL: source.url),
              systemEngine.consumeQueuedTransition() else { return false }
        gaplessBridge.wasSelected = true
        stopSystemPlayerProgressWatchdog()
        let advanced = await finalizeGaplessBridge(epoch: epoch, completedNaturally: false)
        if systemPlayback.isActive { startSystemPlayerProgressWatchdog(generation: systemPlayback.generation) }
        return advanced
    }

    func handleEndOfTrack(
        engineConfirmed: Bool = false,
        finishedEntryIdentifier: String? = nil
    ) async {
        guard seekState == .idle, Date() >= systemPlayback.seekSettleDeadline,
              !isTrackTransitionPending else { return }
        guard finishedEntryIdentifier == nil || !systemPlayback.isActive else { return }
        // AVQueuePlayer owns the armed transition; its currentItem observer confirms the swap.
        if systemPlayback.isActive, systemEngine.hasQueuedItem { return }
        guard !isRestoringSession, pendingRestoreInfo == nil, restorePauseTask == nil else {
            Logger.player.warning("[END-OF-TRACK] suppressed — session restore in progress")
            return
        }
        guard !isHandlingEndOfTrack else {
            Logger.player.warning("[END-OF-TRACK] already handling — skipping duplicate")
            return
        }
        guard Date().timeIntervalSince(lastEndOfTrackTransitionAt) >= 0.75 else {
            Logger.player.debug("[END-OF-TRACK] duplicate EOF/watchdog event ignored")
            return
        }
        if let finishedEntryIdentifier,
           finishedEntryIdentifier != currentSource?.url.absoluteString,
           finishedEntryIdentifier != currentSource?.transcodeRequest(at: streamTimeOffset)?.url.absoluteString {
            Logger.player.debug("[END-OF-TRACK] stale engine entry ignored")
            return
        }
        let epochAtEntry = playbackEpoch
        let eofSnapshot = await MainActor.run { (state.duration, state.position, state.playbackState) }
        guard epochAtEntry == playbackEpoch, eofSnapshot.2.hasPlaybackIntent,
              !isTrackTransitionPending else { return }
        let eofPosition = max(engineProgress(), eofSnapshot.1)
        if currentSource.map(AudioQualityClassifier.isLossyTranscodeStream) == true,
           Self.isPrematureTranscodeEnd(duration: eofSnapshot.0, offset: streamTimeOffset, position: eofPosition) {
            // A truncated encoder response is a transport failure, never a completed listen
            // or a repeat-one request. Retry at the retained position once, then expose failure.
            await recoverPrematureTranscodeEnd(position: eofPosition)
            return
        }
        let trackIdAtEntry = await MainActor.run { state.currentTrack?.id }
        isHandlingEndOfTrack = true
        defer { isHandlingEndOfTrack = false }
        let trackIdNow = await MainActor.run { state.currentTrack?.id }
        guard epochAtEntry == playbackEpoch, trackIdAtEntry == trackIdNow,
              seekState == .idle, Date() >= systemPlayback.seekSettleDeadline else {
            Logger.player.debug("[END-OF-TRACK] ignored — track changed during skip")
            return
        }
        lastEndOfTrackTransitionAt = Date()
        let repeatMode = await MainActor.run { state.repeatMode }
        if repeatMode != .one,
           await engineMovedIntoArmedEntry(epoch: epochAtEntry),
           await finalizeGaplessBridge(epoch: epochAtEntry) {
            // The queued entry is audibly advancing. App state can now follow it without
            // re-creating the engine or requiring a manual resume.
            Logger.player.info("[GAPLESS] transition confirmed by engine start/progress")
            return
        }
        guard await MainActor.run(body: { state.playbackState != .paused }) else { return }
        if gaplessBridge.next != nil {
            // EOF alone is not proof that the queued entry started. Flush an entry that did not
            // advance during the grace window and take the regular play path instead of publishing
            // the next title over a paused transport.
            cancelGaplessBridge()
        }
        if repeatMode == .one {
            wasTrackCompletedNaturally = true
            await recordCurrentTrackPlayback(trigger: "repeat_one")
            wasTrackCompletedNaturally = false
            resetTrackAccumulator(isPlaying: false)
            if let source = currentSource {
                fadeOutTask?.cancel(); fadeOutTask = nil
                fadeInTask?.cancel(); fadeInTask = nil
                isFadingOut = false
                setEngineVolume(restoredVolume)
                await MainActor.run { state.playbackState = .loading }
                let song = await MainActor.run { state.currentTrack }
                #if os(iOS)
                let useSystem = song.map { AudioQualityClassifier.requiresSystemPlayer($0) } == true
                    || PlayerService.isWirelessSystemRouteActive()
                    || systemPlayback.isActive
                #else
                let useSystem = true
                #endif
                startEnginePlayback(
                    url: source.url,
                    headers: source.customHeaders,
                    useSystemPlayer: useSystem
                )
            }
        } else {
            wasTrackCompletedNaturally = true
            guard epochAtEntry == playbackEpoch else {
                Logger.player.debug("[END-OF-TRACK] ignored — playback advanced before skip")
                return
            }
            do {
                try await skipToNext()
            } catch {
                Logger.player.error("[TRANSITION] handleEndOfTrack: skipToNext() failed: \(error, privacy: .public)")
            }
        }
    }

    /// Grace window for a bridged transition that the end-of-track watchdog reached first.
    ///
    /// The watchdog runs off the *metadata* duration, which is frequently a little shorter than the
    /// real stream. It can therefore fire while the engine is still finishing the current entry and
    /// about to switch into the pre-buffered one. Tearing the bridge down at that moment is what
    /// produced "one second of the next track, then silence, then it plays from the beginning":
    /// the engine had already advanced, and `play()` restarted it from zero.
    ///
    /// Returns true when the engine demonstrably moved into the armed entry (its clock came back
    /// to ~0, or it jumped backwards by more than a second), or when app state already advanced.
    private func engineMovedIntoArmedEntry(epoch: UInt64) async -> Bool {
        guard gaplessBridge.next != nil, !systemPlayback.isActive else { return false }
        let baseline = engineProgress()
        var previous = baseline
        let startedAt = Date()
        let deadline = startedAt.addingTimeInterval(Self.bridgedEntryGracePeriod)
        while Date() < deadline {
            if epoch != playbackEpoch { return true }
            let progress = engineProgress()
            let state = activeEngine.state
            if Self.confirmsBridgedEntryProgress(
                previous: previous,
                current: progress,
                engineState: state
            ) {
                return true
            }
            // Normal selection briefly reports buffering. Do not pause the audio graph
            // unless the selected entry has actually remained motionless for a grace period.
            let wantsPlayback = await MainActor.run { self.state.playbackState != .paused }
            guard wantsPlayback, epoch == playbackEpoch else { return false }
            if Self.shouldRecoverBridgedEntry(
                selected: gaplessBridge.wasSelected,
                elapsed: Date().timeIntervalSince(startedAt),
                previous: previous, current: progress, engineState: state
            ) {
                recoverQueuedAudioStreamingTransitionIfNeeded()
            }
            previous = progress
            do {
                try await Task.sleep(for: .milliseconds(120))
            } catch {
                return false
            }
        }
        Logger.player.debug(
            "[GAPLESS] armed entry never appeared in the engine clock — falling back to a normal advance"
        )
        return false
    }

    /// AudioStreaming calls this when it *selects* the queued entry. The callback is emitted while
    /// its internal state is still `waitingForData`, so it is only a hand-off signal and never
    /// proof that audio is moving. Leave the renderer uninterrupted; the progress watchdog
    /// handles recovery only if this selected entry remains stalled.
    func handleEngineStartedEntry(entryIdentifier: String) async {
        guard !gaplessBridge.wasSelected, let armed = gaplessBridge.source else { return }
        guard entryIdentifier == armed.url.absoluteString else { return }
        gaplessBridge.wasSelected = true
        // Some engine handoffs do not emit an EOF stop reason. Start the same progress
        // confirmation from selection as well, so a parked zero clock still gets recovered.
        await handleEndOfTrack(engineConfirmed: true)
    }

    private func recoverQueuedAudioStreamingTransitionIfNeeded() {
        guard !systemPlayback.isActive, !gaplessBridge.recoveryWasRequested else { return }
        gaplessBridge.recoveryWasRequested = true
        (engine as? any AudioStreamingPlaybackEngine)?.recoverQueuedTransitionIfNeeded()
    }

    nonisolated static func shouldRecoverBridgedEntry(
        selected: Bool, elapsed: TimeInterval,
        previous: Double, current: Double, engineState: AudioPlayerState
    ) -> Bool {
        selected && elapsed >= 0.6
            && previous.isFinite && current.isFinite
            && abs(current - previous) < 0.01
            && (engineState == .bufferring || engineState == .paused)
    }

    private nonisolated static let bridgedEntryGracePeriod: TimeInterval = 2.5
    /// Engine progress below this means the engine restarted its clock, i.e. it moved on to the
    /// pre-buffered entry.
    private nonisolated static let bridgedEntryProgressResetThreshold: Double = 2.0

    /// A zero clock at EOF is ambiguous: it can mean the queued entry is playing, or that the
    /// completed transport is parked. Require both a playing engine and forward clock motion (or
    /// an obvious wrap) before treating it as a successful gapless handoff.
    nonisolated static func confirmsBridgedEntryProgress(
        previous: Double,
        current: Double,
        engineState: AudioPlayerState
    ) -> Bool {
        guard engineState == .playing, previous.isFinite, current.isFinite else { return false }
        if previous > Self.bridgedEntryProgressResetThreshold, current + 1 < previous {
            return true
        }
        return current < Self.bridgedEntryProgressResetThreshold && current > previous + 0.02
    }

    /// Completes a seamless gapless transition. Returns `true` when a bridge was armed and the
    /// engine already advanced to its pre-buffered next entry, in which case app state is advanced
    /// in place — the engine must NOT be restarted.
    func finalizeGaplessBridge(epoch: UInt64, completedNaturally: Bool = true) async -> Bool {
        guard let next = gaplessBridge.next, let nextSource = gaplessBridge.source else {
            return false
        }
        guard epoch == playbackEpoch, gaplessBridge.epoch == epoch else {
            gaplessBridge.clearPreparedSource()
            return false
        }
        // The pre-queued entry must still be the queue's actual next track. If the queue was
        // mutated (remove / move / clear) after arming, finalizing would advance app state to a
        // track the engine may no longer be playing — or to an out-of-range index — which shows
        // up as "jumped back to the start / repeating". Fall back to the normal skipToNext path.
        let (queue, currentIndex) = await MainActor.run { (state.queue, state.currentIndex) }
        let expectedNextIndex = currentIndex + 1
        guard queue.indices.contains(expectedNextIndex), queue[expectedNextIndex].id == next.id else {
            Logger.player.warning("[GAPLESS] bridge stale — queue changed after arming; falling back to normal advance")
            cancelGaplessBridge()
            return false
        }
        wasTrackCompletedNaturally = completedNaturally
        await recordCurrentTrackPlayback(trigger: completedNaturally ? "track_completed" : "user_skipped")
        guard epoch == playbackEpoch else { return true }
        wasTrackCompletedNaturally = false
        resetTrackAccumulator(isPlaying: false)
        playbackEpoch &+= 1
        let bridgedEpoch = playbackEpoch

        let nextIndex = expectedNextIndex
        let duration = next.duration
        let isTranscoding = AudioQualityClassifier.isLossyTranscodeStream(nextSource)

        cancelPendingScrobble()
        musicHapticsNudgeTask?.cancel()
        musicHapticsNudgeTask = nil
        nextTrackISRCPrefetchTask?.cancel()
        nextTrackISRCPrefetchTask = nil

        nowPlayingEpoch &+= 1
        lastNowPlayingPushDate = .distantPast
        let config = await MainActor.run { replayGainSettings.config }
        guard bridgedEpoch == playbackEpoch else { return true }
        await replayGainService?.apply(track: next, config: config)
        guard bridgedEpoch == playbackEpoch else { return true }

        let previousJellyfinContext = currentSource?.jellyfinPlaybackContext
        let previousPosition = await MainActor.run { state.position }
        currentSource = nextSource
        streamTimeOffset = 0
        systemPlayback.resetTrackRecovery()
        cancelPendingCacheDownload()
        cancelPendingPrefetch()
        gaplessBridge.clearPreparedSource()
        gaplessBridge.wasSelected = false
        gaplessBridge.recoveryWasRequested = false
        endOfTrackStallStartedAt = nil
        endOfTrackStallProgress = -1
        lastObservedEngineProgress = 0
        underrunCountForCurrentTrack = 0
        didAdaptQualityForCurrentTrack = false
        seekState = .idle
        let bridgedSeekable = engineIsSeekable()
        let isAudible = systemPlayback.isActive ? systemEngine.state == .playing : engine.state == .playing
        if isAudible { currentPlaySegmentStart = Date() }

        await MainActor.run {
            state.currentTrack = next
            state.currentIndex = nextIndex
            state.duration = duration
            state.position = 0
            state.isSeekable = bridgedSeekable
            state.playbackState = isAudible ? .playing : .loading
            state.isPlaybackAvailable = true
            state.isDeliveringTranscodedAudio = isTranscoding
        }
        guard bridgedEpoch == playbackEpoch else { return true }

        let bridgedQueueCount = await MainActor.run { state.queue.count }
        guard bridgedEpoch == playbackEpoch else { return true }
        await nowPlayingService?.publishTrackChange(NowPlayingSnapshot(
            title: next.title,
            artist: next.artist,
            album: next.albumName,
            duration: duration,
            position: 0,
            playbackRate: isAudible ? 1.0 : 0.0,
            artworkURL: nil,
            artworkHeaders: [:],
            coverArtId: next.effectiveCoverArtId,
            albumId: next.albumId,
            isLiveStream: false,
            radioStationName: nil,
            isrc: cachedISRC(for: next),
            trackId: next.id,
            queueIndex: nextIndex,
            queueCount: bridgedQueueCount
        ))
        guard bridgedEpoch == playbackEpoch else { return true }

        nextGaplessPreparationAttempt = .distantPast
        // Release the handover/EOF guard now. Artwork, session persistence and recommendations
        // must not prevent the progress loop from prebuffering the following track.
        gaplessMetadataTask = Task { [weak self] in
            await self?.finishBridgedMetadata(next: next, source: nextSource, epoch: bridgedEpoch,
                                            nextIndex: nextIndex, queueCount: bridgedQueueCount,
                                            previousContext: previousJellyfinContext, previousPosition: previousPosition)
        }
        Logger.player.info("[GAPLESS] bridged to '\(next.title, privacy: .public)'")
        return true
    }

    private func finishBridgedMetadata(next: DisplayableSong, source: MediaSource, epoch: UInt64,
                                       nextIndex: Int, queueCount: Int,
                                       previousContext: JellyfinPlaybackContext?, previousPosition: TimeInterval) async {
        guard epoch == playbackEpoch, !Task.isCancelled else { return }
        if let serverId = await MainActor.run(body: { serverService.state.activeServer?.id }) {
            await scheduleAutomaticDownload(song: next, serverId: serverId)
        }
        guard epoch == playbackEpoch, !Task.isCancelled else { return }

        let artworkURL = await resolveArtworkURL(for: next)
        guard epoch == playbackEpoch, !Task.isCancelled else { return }
        let artworkHeaders: [String: String]
        do {
            artworkHeaders = try await serverService.activeCredentials().customHeaders
        } catch {
            artworkHeaders = [:]
        }
        let transport = await MainActor.run { (state.position, state.playbackState) }
        guard epoch == playbackEpoch, !Task.isCancelled else { return }
        await nowPlayingService?.update(with: NowPlayingSnapshot(
            title: next.title,
            artist: next.artist,
            album: next.albumName,
            duration: next.duration,
            position: transport.0,
            playbackRate: transport.1 == .playing ? 1.0 : 0.0,
            artworkURL: artworkURL,
            artworkHeaders: artworkHeaders,
            coverArtId: next.effectiveCoverArtId,
            albumId: next.albumId,
            isLiveStream: false,
            radioStationName: nil,
            isrc: cachedISRC(for: next),
            trackId: next.id,
            queueIndex: nextIndex,
            queueCount: queueCount
        ))
        guard epoch == playbackEpoch, !Task.isCancelled else { return }
        if Self.isListeningHistoryEnabled {
            Task { [libraryService] in
                await libraryService.scrobble(songId: next.id, submission: false)
            }
        }
        if let ws = widgetSyncService {
            Task { await ws.onTrackStarted(next) }
        }
        await saveSession()
        guard epoch == playbackEpoch, !Task.isCancelled else { return }
        preloadNextTrackArtwork()
        await evaluateAutoExtend()
        guard epoch == playbackEpoch, !Task.isCancelled else { return }
        if let previousContext {
            await reportJellyfinStopped(previousContext, position: previousPosition)
        }
        guard epoch == playbackEpoch, !Task.isCancelled else { return }
        if let context = source.jellyfinPlaybackContext {
            await reportJellyfinStarted(context, position: 0)
        }
        guard epoch == playbackEpoch, !Task.isCancelled else { return }
        let currentTransport = await MainActor.run { (state.position, state.playbackState) }
        guard currentTransport.1 == .playing, epoch == playbackEpoch, !Task.isCancelled else { return }
        await reportOpenSubsonicPlayback(state: .playing, songId: next.id, positionMs: Int(currentTransport.0 * 1000))
    }

    func pauseAtEndOfQueue() async {
        await recordCurrentTrackPlayback(trigger: "end_of_queue")
        wasTrackCompletedNaturally = false
        accumulatedPlayedSeconds = 0
        currentPlaySegmentStart = nil
        trackPlayStartDate = nil

        cancelFadeTasks()
        stopProgressTimer()
        stopPositionSaveTimer()
        stopEngine()
        #if os(iOS)
        sessionActivationRetryTask?.cancel()
        sessionActivationRetryTask = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        pendingRestoreInfo = nil
        stoppedAtEndOfQueue = true

        Logger.player.info("[PLAYBACK] End of queue (repeat off)")

        let duration = await MainActor.run { state.duration }
        await MainActor.run {
            state.playbackState = .paused
            state.position = duration
        }
        await pushPositionSnapshot(rate: 0)
        await saveSession()

        let endTrack = await MainActor.run { state.currentTrack }
        if let ws = widgetSyncService {
            Task { [weak ws] in await ws?.onPlayStateChanged(isPlaying: false, currentSong: endTrack) }
        }
    }
}
