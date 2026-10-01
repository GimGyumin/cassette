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
              pendingSeekTarget == nil,
              gaplessBridgeNext == nil, gaplessPreparationTask == nil,
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
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard epoch == playbackEpoch, !Task.isCancelled else { return }
            let isPlaying = usingSystemPlayer
                ? systemEngine.state == .playing : engine.state == .playing
            if isPlaying {
                await scheduleGaplessPreQueue(current: current, serverId: serverId, epoch: epoch)
                return
            }
        }
    }

    func scheduleGaplessPreQueue(current: DisplayableSong, serverId: UUID, epoch: UInt64) async {
        guard epoch == playbackEpoch, !Task.isCancelled else { return }
        guard gaplessBridgeNext == nil else { return }
        let systemGeneration = systemPlayerGeneration
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
        let requiresSystemPlayer = !usingSystemPlayer && AudioQualityClassifier.requiresSystemPlayer(next)

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
              systemGeneration == systemPlayerGeneration,
              usingSystemPlayer || nextSource.url.pathExtension.lowercased() != "m3u8" else { return }
        let nextIsStillQueued = await MainActor.run {
            state.repeatMode != .one && state.queue.indices.contains(state.currentIndex + 1)
                && state.queue[state.currentIndex + 1].id == next.id
        }
        guard nextIsStillQueued, epoch == playbackEpoch, !Task.isCancelled,
              gaplessBridgeNext == nil, preparationGeneration == gaplessPreparationGeneration else { return }
        gaplessBridgeNext = next
        gaplessBridgeSource = nextSource
        gaplessBridgeEpoch = epoch
        bridgedEntryDidStart = false
        if usingSystemPlayer {
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

    func handleEndOfTrack(
        engineConfirmed: Bool = false,
        finishedEntryIdentifier: String? = nil
    ) async {
        guard finishedEntryIdentifier == nil || !usingSystemPlayer else { return }
        // AVQueuePlayer owns the armed transition; its currentItem observer confirms the swap.
        if usingSystemPlayer, systemEngine.hasQueuedItem { return }
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
           finishedEntryIdentifier != currentSource?.url.absoluteString {
            Logger.player.debug("[END-OF-TRACK] stale engine entry ignored")
            return
        }
        let epochAtEntry = playbackEpoch
        let trackIdAtEntry = await MainActor.run { state.currentTrack?.id }
        isHandlingEndOfTrack = true
        defer { isHandlingEndOfTrack = false }
        let trackIdNow = await MainActor.run { state.currentTrack?.id }
        guard epochAtEntry == playbackEpoch, trackIdAtEntry == trackIdNow else {
            Logger.player.debug("[END-OF-TRACK] ignored — track changed during skip")
            return
        }
        lastEndOfTrackTransitionAt = Date()
        let repeatMode = await MainActor.run { state.repeatMode }
        if repeatMode != .one,
           engineConfirmed,
           await finalizeGaplessBridge(epoch: epochAtEntry) {
            // The AudioStreaming engine already advanced into the pre-buffered next entry
            // seamlessly (its `.finishPlaying` fired EOF for the completed track); app state
            // was updated in place — no `play()` call, no re-created gap.
            return
        }
        if !engineConfirmed, repeatMode != .one,
           await engineMovedIntoArmedEntry(epoch: epochAtEntry),
           await finalizeGaplessBridge(epoch: epochAtEntry) {
            // The watchdog fired *while* the engine was switching into the pre-buffered entry and
            // the switch completed during the grace window. Advancing app state in place is the
            // whole point of the bridge; falling through here would restart the track from zero.
            Logger.player.info("[GAPLESS] transition confirmed by the engine clock after the watchdog fired")
            return
        }
        if !engineConfirmed {
            // The watchdog fired without proof that the engine consumed its queued entry.
            // Flush that entry and take the normal play() path so app and engine indices
            // cannot diverge and replay the same audio under newer lock-screen metadata.
            cancelGaplessBridge()
        }
        if repeatMode == .one {
            wasTrackCompletedNaturally = true
            await recordCurrentTrackPlayback(trigger: "repeat_one")
            wasTrackCompletedNaturally = false
            resetTrackAccumulator(isPlaying: true)
            if let source = currentSource {
                fadeOutTask?.cancel(); fadeOutTask = nil
                fadeInTask?.cancel(); fadeInTask = nil
                isFadingOut = false
                setEngineVolume(restoredVolume)
                let song = await MainActor.run { state.currentTrack }
                #if os(iOS)
                let useSystem = song.map { AudioQualityClassifier.requiresSystemPlayer($0) } == true
                    || PlayerService.isWirelessSystemRouteActive()
                    || usingSystemPlayer
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
        guard gaplessBridgeNext != nil, !usingSystemPlayer else { return false }
        // Strongest evidence first: the engine told us it started the pre-buffered entry.
        if bridgedEntryDidStart { return true }
        let baseline = engineProgress()
        let deadline = Date().addingTimeInterval(Self.bridgedEntryGracePeriod)
        while Date() < deadline {
            if epoch != playbackEpoch { return true }
            if bridgedEntryDidStart { return true }
            let progress = engineProgress()
            if progress < Self.bridgedEntryProgressResetThreshold { return true }
            if progress + 1.0 < baseline { return true }
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

    /// Records that the engine began playing an entry, so the end-of-track watchdog can tell a
    /// completed bridged transition from a genuinely stalled one.
    func handleEngineStartedEntry(entryIdentifier: String) {
        guard !bridgedEntryDidStart, let armed = gaplessBridgeSource else { return }
        guard entryIdentifier == armed.url.absoluteString else { return }
        bridgedEntryDidStart = true
    }

    private nonisolated static let bridgedEntryGracePeriod: TimeInterval = 2.5
    /// Engine progress below this means the engine restarted its clock, i.e. it moved on to the
    /// pre-buffered entry.
    private nonisolated static let bridgedEntryProgressResetThreshold: Double = 2.0

    /// Completes a seamless gapless transition. Returns `true` when a bridge was armed and the
    /// engine already advanced to its pre-buffered next entry, in which case app state is advanced
    /// in place — the engine must NOT be restarted.
    func finalizeGaplessBridge(epoch: UInt64) async -> Bool {
        guard let next = gaplessBridgeNext, let nextSource = gaplessBridgeSource else {
            return false
        }
        guard epoch == playbackEpoch, gaplessBridgeEpoch == epoch else {
            gaplessBridgeNext = nil
            gaplessBridgeSource = nil
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
        await recordCurrentTrackPlayback(trigger: "track_completed")
        guard epoch == playbackEpoch else { return true }
        wasTrackCompletedNaturally = false
        resetTrackAccumulator(isPlaying: true)
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
        didRecoverFromStalledStream = false
        cancelPendingCacheDownload()
        cancelPendingPrefetch()
        gaplessBridgeNext = nil
        gaplessBridgeSource = nil
        bridgedEntryDidStart = false
        endOfTrackStallStartedAt = nil
        endOfTrackStallProgress = -1
        lastObservedEngineProgress = 0
        underrunCountForCurrentTrack = 0
        didAdaptQualityForCurrentTrack = false
        pendingSeekTarget = nil
        pendingSeekDeadline = .distantPast
        let bridgedSeekable = engineIsSeekable()

        await MainActor.run {
            state.currentTrack = next
            state.currentIndex = nextIndex
            state.duration = duration
            state.position = 0
            state.isSeekable = bridgedSeekable
            state.playbackState = .playing
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
            playbackRate: 1.0,
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

        if let serverId = await MainActor.run(body: { serverService.state.activeServer?.id }) {
            await scheduleAutomaticDownload(song: next, serverId: serverId)
        }
        guard bridgedEpoch == playbackEpoch else { return true }

        let artworkURL = await resolveArtworkURL(for: next)
        guard bridgedEpoch == playbackEpoch else { return true }
        let artworkHeaders: [String: String]
        do {
            artworkHeaders = try await serverService.activeCredentials().customHeaders
        } catch {
            artworkHeaders = [:]
        }
        guard bridgedEpoch == playbackEpoch else { return true }
        await nowPlayingService?.update(with: NowPlayingSnapshot(
            title: next.title,
            artist: next.artist,
            album: next.albumName,
            duration: duration,
            position: 0,
            playbackRate: 1.0,
            artworkURL: artworkURL,
            artworkHeaders: artworkHeaders,
            coverArtId: next.effectiveCoverArtId,
            albumId: next.albumId,
            isLiveStream: false,
            radioStationName: nil,
            isrc: cachedISRC(for: next),
            trackId: next.id,
            queueIndex: nextIndex,
            queueCount: bridgedQueueCount
        ))
        if Self.isListeningHistoryEnabled {
            Task { [libraryService] in
                await libraryService.scrobble(songId: next.id, submission: false)
            }
        }
        if let ws = widgetSyncService {
            Task { await ws.onTrackStarted(next) }
        }
        await saveSession()
        preloadNextTrackArtwork()
        await evaluateAutoExtend()
        nextGaplessPreparationAttempt = .distantPast
        // The progress loop schedules the following entry after this handover finishes.
        await reportOpenSubsonicPlayback(state: .playing, songId: next.id, positionMs: 0)
        if let previousJellyfinContext {
            await reportJellyfinStopped(previousJellyfinContext, position: previousPosition)
        }
        if let context = nextSource.jellyfinPlaybackContext {
            await reportJellyfinStarted(context, position: 0)
        }
        Logger.player.info("[GAPLESS] bridged to '\(next.title, privacy: .public)'")
        return true
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
