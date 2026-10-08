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
    // MARK: - Play

    func play(tracks: [DisplayableSong], startIndex: Int) async throws {
        try await play(tracks: tracks, startIndex: startIndex, preservePlayingState: false)
    }

    /// Starts queue playback at `startIndex`. Track-to-track transitions reuse preparation
    /// when possible. Transport state stays loading until the engine confirms playback.
    func play(
        tracks: [DisplayableSong],
        startIndex: Int,
        preservePlayingState: Bool
    ) async throws {
        guard tracks.indices.contains(startIndex) else { return }
        playbackRequestTask?.cancel()
        playbackRequestID &+= 1
        let requestID = playbackRequestID
        let task = Task {
            try await self.performPlay(
                tracks: tracks, startIndex: startIndex, preservePlayingState: preservePlayingState
            )
        }
        playbackRequestTask = task
        defer {
            if requestID == playbackRequestID { playbackRequestTask = nil }
        }
        do {
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        } catch is CancellationError {
            // Superseded selection or pause/stop is not a playback failure.
        }
    }

    private func performPlay(
        tracks: [DisplayableSong], startIndex: Int, preservePlayingState: Bool
    ) async throws {
        try Task.checkCancellation()
        playbackAcquisitionTask?.cancel()
        playbackAcquisitionTask = nil
        let previousQueueCount = await MainActor.run { state.queue.count }
        try Task.checkCancellation()
        guard tracks.indices.contains(startIndex) else {
            Logger.player.error(
                "[PLAY] out-of-range startIndex — tracks=\(tracks.count, privacy: .public) startIndex=\(startIndex, privacy: .public) previousQueueCount=\(previousQueueCount, privacy: .public) — aborting play()"
            )
            return
        }
        Logger.player.info(
            "[PLAY] tracks=\(tracks.count, privacy: .public) startIndex=\(startIndex, privacy: .public) previousQueueCount=\(previousQueueCount, privacy: .public) preservePlayingState=\(preservePlayingState, privacy: .public)"
        )
        // A new play()/tap supersedes any in-flight background transfer for the previous track.
        // Cancelling here — not in `startPlayback`, which runs *after* the resolve below — keeps
        // the previous track's cache download from competing with this resolve on a slow link,
        // which is what made a freshly tapped track appear "stuck" behind the previous one.
        cancelPendingCacheDownload()
        cancelPendingPrefetch()

        let currentQueueIds = await MainActor.run { state.queue.map(\.id) }
        // A play request for the track that is *already* playing must not tear the engine down and
        // restart it at 0:00. A re-mounted list view, a re-sent tap, a queue re-sync or an App Intent
        // can all re-issue the same request mid-track — that is what made a song jump back to the
        // beginning part-way through. A genuine restart still works: it either targets a different
        // queue or the scrubber is still at the start.
        let alreadyPlaying = await MainActor.run {
            (
                trackId: state.currentTrack?.id,
                position: state.position,
                playbackState: state.playbackState
            )
        }
        if !isTrackTransitionPending, progressTask != nil,
           alreadyPlaying.trackId == tracks[startIndex].id,
           tracks.map(\.id) == currentQueueIds,
           alreadyPlaying.position > 2,
           alreadyPlaying.playbackState.hasPlaybackIntent {
            let caller = Thread.callStackSymbols.dropFirst().prefix(6).joined(separator: " ← ")
            Logger.player.warning(
                "[PLAY] '\(tracks[startIndex].title, privacy: .public)' is already playing at \(alreadyPlaying.position, format: .fixed(precision: 1))s — ignoring the duplicate start request. Caller: \(caller, privacy: .public)"
            )
            return
        }
        try Task.checkCancellation()
        if await advancePreparedSystemTrack(tracks: tracks, startIndex: startIndex) { return }
        try Task.checkCancellation()
        // The AudioStreaming fallback still needs an engine start for an explicit selection,
        // but it can reuse the resolved URL/headers instead of negotiating the source again.
        let preparedSource = gaplessBridge.epoch == playbackEpoch
            && gaplessBridge.next?.id == tracks[startIndex].id
            && tracks.map(\.id) == currentQueueIds ? gaplessBridge.source : nil
        stoppedAtEndOfQueue = false
        playbackEpoch &+= 1
        let epoch = playbackEpoch
        cancelGaplessBridge()
        if tracks.map(\.id) != currentQueueIds {
            originalQueueOrder = nil
            await MainActor.run {
                state.isShuffled = false
                state.originalQueueEndIndex = nil
                if state.isSmartShuffleActive {
                    state.isSmartShuffleActive = false
                    Logger.player.debug("Ending Smart Shuffle session — starting new explicit queue")
                }
            }
        }

        guard let serverId = await MainActor.run(body: { serverService.state.activeServer?.id }) else {
            await MainActor.run { state.playbackState = .error(.serverNotConfigured) }
            throw CassetteError.serverNotConfigured
        }

        try Task.checkCancellation()
        let song = tracks[startIndex]
        // Capture the outgoing track before the visible track flips: listening history must still
        // be attributed to the song the listener actually heard.
        if !isTrackTransitionPending {
            outgoingSourceForHistory = currentSource
            outgoingPositionForHistory = engineProgress()
            outgoingTrackForHistory = await MainActor.run { state.currentTrack }
            finalizePlaySegment()
        }
        try Task.checkCancellation()
        // The engine still belongs to the outgoing track until `startPlayback` takes over, so the
        // end-of-track watchdog must know a hand-over is in flight. Set *before* the state flip:
        // the progress ticker below reads it on its next 500 ms pass.
        isTrackTransitionPending = true
        let transitionStartedAt = Date()
        self.transitionStartedAt = transitionStartedAt
        // Kept until audio actually starts, so the log can report the latency the listener perceives
        // (engine hand-over *plus* server transcode warm-up and AVPlayer buffering).
        self.systemPlayback.transitionRequestedAt = transitionStartedAt
        // The listener picked another song: silence the outgoing one *now*, not after the network
        // resolve. A hand-over that kept the previous track audible until the new item started reads as
        // "the old song is still playing", which is worse than a short gap.
        stopEngine()
        currentSource = nil
        // The progress ticker keeps running (it also drives scrobbling, prefetch and fade-out), but
        // it stops *attributing* the outgoing engine's clock to the incoming track while the flag
        // above is set — see `startProgressTimer`. That was the bug behind a skip showing the
        // previous track's progress under the new title.
        await MainActor.run {
            if state.currentRadio != nil {
                Logger.player.debug("Ending live stream session — switching to queue playback")
            }
            state.queue = tracks
            state.currentIndex = startIndex
            state.currentRadio = nil
            // Flip the visible track *now*. Resolving the stream below can wait on the network
            // (Jellyfin playbackInfo, credentials, a slow server), and making the title and
            // artwork wait for it is what made a skip feel like it took seconds to change track.
            state.currentTrack = song
            // Take the scrubber with it. Leaving the outgoing track's duration/position in place
            // while the ticker ran is what showed the *previous* track's progress under the new
            // track. Starting at 0:00 with the new duration is honest for the whole hand-over.
            state.duration = song.duration
            state.position = 0
            state.isSeekable = song.duration > 0
            state.playbackState = .loading
        }

        var source: MediaSource
        do {
            if preparedSource != nil,
               let local = await downloadService.downloadedURL(forSongId: song.id, serverId: serverId) {
                source = .downloaded(local)
            } else if preparedSource != nil,
                      let local = await cacheService.cachedURL(forSongId: song.id, serverId: serverId) {
                source = .cached(local)
            } else if let preparedSource,
               !preparedSource.isLocal || FileManager.default.fileExists(atPath: preparedSource.url.path) {
                source = preparedSource
                Logger.player.debug("[PLAY] reusing prepared source for '\(song.id, privacy: .public)'")
            } else {
                source = try await mediaResolver.resolve(songId: song.id, serverId: serverId, song: song)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let e as CassetteError {
            guard epoch == playbackEpoch, !Task.isCancelled else { return }
            isTrackTransitionPending = false
            await MainActor.run { state.playbackState = .error(e) }
            throw e
        } catch {
            guard epoch == playbackEpoch, !Task.isCancelled else { return }
            // A transient (non-CassetteError) resolve failure — keychain race, network
            // blip, or credential reentry — usually clears on a single retry. Retry once
            // so intermittent "nothing played" doesn't silently park the player in `.idle`.
            Logger.player.error("Playback resolve failed for '\(song.title, privacy: .public)' (id=\(song.id, privacy: .public)): \(String(describing: error), privacy: .public) — retrying once")
            try await Task.sleep(for: .milliseconds(450))
            guard epoch == playbackEpoch, !Task.isCancelled else { return }
            do {
                source = try await mediaResolver.resolve(songId: song.id, serverId: serverId, song: song)
                Logger.player.info("Playback resolve retry succeeded for '\(song.title, privacy: .public)'")
            } catch let e as CassetteError {
                guard epoch == playbackEpoch, !Task.isCancelled else { return }
                isTrackTransitionPending = false
                await MainActor.run { state.playbackState = .error(e) }
                throw e
            } catch {
                guard epoch == playbackEpoch, !Task.isCancelled else { return }
                isTrackTransitionPending = false
                Logger.player.error("Playback resolve retry failed for '\(song.title, privacy: .public)': \(String(describing: error), privacy: .public)")
                await MainActor.run { state.playbackState = .error(.timeout) }
                throw error
            }
        }

        guard epoch == playbackEpoch, !Task.isCancelled else { return }
        gaplessBridge.clearPreparedSource()
        Logger.player.info(
            "[TRANSITION-TIMING] resolve finished in \(Int(Date().timeIntervalSince(transitionStartedAt) * 1000), privacy: .public)ms for '\(song.title, privacy: .public)' (id=\(song.id, privacy: .public) queueIndex=\(startIndex, privacy: .public))"
        )
        await startPlayback(song: song, source: source, serverId: serverId, epoch: epoch, preservePlayingState: preservePlayingState)
    }

    func startPlayback(
        song: DisplayableSong,
        source: MediaSource,
        serverId: UUID,
        epoch: UInt64,
        preservePlayingState: Bool
    ) async {
        let previousJellyfinContext = outgoingSourceForHistory?.jellyfinPlaybackContext
        let previousPosition = outgoingPositionForHistory
        guard epoch == playbackEpoch, !Task.isCancelled else {
            Logger.player.debug("[TRANSITION] dropped stale startPlayback for '\(song.title, privacy: .public)'")
            return
        }
        await recordCurrentTrackPlayback(
            trigger: wasTrackCompletedNaturally ? "track_completed" : "user_skipped",
            overridingTrack: outgoingTrackForHistory
        )
        guard epoch == playbackEpoch, !Task.isCancelled else {
            Logger.player.debug("[TRANSITION] dropped stale startPlayback after history update for '\(song.title, privacy: .public)'")
            return
        }
        outgoingTrackForHistory = nil
        outgoingSourceForHistory = nil
        wasTrackCompletedNaturally = false
        // A fresh track starts with a clean slate: one underrun is a hiccup, and the ceiling we
        // learned from the previous track is remembered on `streamingSettings`, not here.
        underrunCountForCurrentTrack = 0
        didAdaptQualityForCurrentTrack = false
        systemPlayback.resetTrackRecovery()
        progressStallMonitor = PlaybackStallMonitor()
        // The new track is still preparing; do not count artwork/lyrics loading time as listening.
        resetTrackAccumulator(isPlaying: false)
        #if os(iOS)
        // Background auto-skip must not keep the previous track's scrubber as a health-check anchor
        // (that falsely rebuilds the new track from e.g. 153s while engine is at 40s).
        lastForegroundProgress = 0
        lastForegroundProgressSongId = song.id
        #endif

        cancelPendingScrobble()
        cancelPendingCacheDownload()
        cancelPendingPrefetch()
        musicHapticsNudgeTask?.cancel()
        musicHapticsNudgeTask = nil
        nextTrackISRCPrefetchTask?.cancel()
        nextTrackISRCPrefetchTask = nil

        // Stop progress timer + detach prior Music Haptics before audio/engine work.
        stopProgressTimer()
        nowPlayingEpoch &+= 1
        lastNowPlayingPushDate = .distantPast
        await nowPlayingService?.setPlaybackRate(0)
        guard epoch == playbackEpoch, !Task.isCancelled else { return }
        await nowPlayingService?.clearISRC()
        guard epoch == playbackEpoch, !Task.isCancelled else { return }
        // The previous track is already silent: `stopEngine()` runs the moment a song is picked, so this
        // is the belt-and-braces stop for the paths that reach `startPlayback` directly.
        stopEngine()
        if let previousJellyfinContext {
            Task { [weak self] in
                await self?.reportJellyfinStopped(previousJellyfinContext, position: previousPosition)
            }
        }

        let shouldFadeIn = isFadingOut && crossfadeConfig.duration > 0
        fadeOutTask?.cancel(); fadeOutTask = nil
        fadeInTask?.cancel(); fadeInTask = nil
        isFadingOut = false

        let config = await MainActor.run { replayGainSettings.config }
        await replayGainService?.apply(track: song, config: config)
        guard epoch == playbackEpoch, !Task.isCancelled else { return }

        // Change the visible track immediately, but keep playback in `.loading` until the
        // engine has been started below.
        await MainActor.run {
            state.currentTrack = song
            state.duration = song.duration
            state.position = 0
            // Keep the scrubber usable while the streaming parser is still discovering
            // its own duration. We already have a finite catalog duration and the engine
            // can queue an early seek request until parsing catches up.
            state.isSeekable = song.duration > 0
            state.playbackState = .loading
        }
        guard epoch == playbackEpoch, !Task.isCancelled else { return }

        let songId = song.id
        if Self.isListeningHistoryEnabled {
            Task { [libraryService] in
                await libraryService.scrobble(songId: songId, submission: false)
            }
            playingNowTask = Task { [listenBrainzService, weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled, Self.isListeningHistoryEnabled, let self else { return }
                let stillActive = await MainActor.run { self.state.playbackState == .playing && self.state.currentTrack?.id == song.id }
                guard stillActive else { return }
                await listenBrainzService.notifyTrackStarted(song: song)
            }
        }

        guard epoch == playbackEpoch, !Task.isCancelled else { return }
        let useSystemPlayer = shouldUseSystemPlayer(for: song, source: source)
        Logger.player.info(
            "[TRANSITION] advancing to '\(song.title, privacy: .public)' (id=\(song.id, privacy: .public)) — engine=\(useSystemPlayer ? "AVPlayer/Spatial" : "AudioStreaming", privacy: .public)"
        )

        endOfTrackStallStartedAt = nil
        endOfTrackStallProgress = -1
        lastObservedEngineProgress = 0
        seekState = .idle
        liveStreamStallTask?.cancel()
        liveStreamStallTask = nil
        currentSource = source
        pendingRestoreInfo = nil

        restorePauseTask?.cancel()
        restorePauseTask = nil
        if isMutedForRestore {
            setEngineVolume(restoredVolume)
            isMutedForRestore = false
        }

        #if os(iOS)
        configureAudioSessionIfNeeded(preferMultichannel: useSystemPlayer)
        #endif

        let fadingInAllowed: Bool
        #if os(iOS)
        fadingInAllowed = shouldFadeIn && !useSystemPlayer && !PlayerService.isWirelessSystemRouteActive()
        #else
        fadingInAllowed = shouldFadeIn && !useSystemPlayer
        #endif

        let duration = song.duration
        resolvedISRCForCurrentTrack = song.isrc
        resolvedISRCSongId = song.id

        let isTranscoding = AudioQualityClassifier.isLossyTranscodeStream(source)
        guard epoch == playbackEpoch, !Task.isCancelled else { return }
        // Publish the incoming track *before* the engine is started: an engine that begins
        // playing immediately (a downloaded or cached file) must not have its own confirmation
        // overwritten by this block.
        await MainActor.run {
            state.currentTrack = song
            state.duration = duration
            state.position = 0
            state.isSeekable = duration > 0
            // A fresh track stays `.loading` until an engine confirms real audio: AVPlayer's
            // time-control status, AudioStreaming's state callback, or measured progress in the
            // progress ticker. Publishing `.playing` here is what made the transport show its
            // pause/stop control for a stream that had not produced a single sample yet.
            state.playbackState = .loading
            state.isPlaybackAvailable = true
            state.isDeliveringTranscodedAudio = isTranscoding
        }
        guard epoch == playbackEpoch, !Task.isCancelled else { return }

        if fadingInAllowed {
            setEngineVolume(0)
        }
        isTrackTransitionPending = false
        resetTrackAccumulator(isPlaying: false)
        startEnginePlayback(
            url: source.url,
            headers: source.customHeaders,
            useSystemPlayer: useSystemPlayer
        )
        if let context = source.jellyfinPlaybackContext {
            Task { [weak self] in await self?.reportJellyfinStarted(context, position: 0) }
        }
        if fadingInAllowed {
            performFadeIn(duration: crossfadeConfig.duration)
        }
        if let started = transitionStartedAt {
            transitionStartedAt = nil
            Logger.player.info(
                "[TRANSITION-TIMING] '\(song.title, privacy: .public)' hand-over completed in \(Int(Date().timeIntervalSince(started) * 1000), privacy: .public)ms (engine=\(useSystemPlayer ? "AVPlayer" : "AudioStreaming", privacy: .public) transcoded=\(isTranscoding, privacy: .public))"
            )
        }
        guard epoch == playbackEpoch, !Task.isCancelled else { return }

        startProgressTimer()
        schedulePlaybackAcquisitionRecovery(song: song, serverId: serverId, epoch: epoch)

        // Audio is already starting. Artwork credentials and MediaSession/Siri registration
        // must not hold up the first frame, including cold starts and cached playback.
        let artworkURL = await resolveArtworkURL(for: song)
        guard epoch == playbackEpoch, !Task.isCancelled else { return }
        let artworkHeaders: [String: String]
        do {
            artworkHeaders = try await serverService.activeCredentials().customHeaders
        } catch {
            Logger.player.warning("[CREDENTIALS] activeCredentials failed, using empty artwork headers: \(error, privacy: .public)")
            artworkHeaders = [:]
        }
        guard epoch == playbackEpoch, !Task.isCancelled else { return }

        let nowPlayingState = await MainActor.run {
            (state.currentIndex, state.queue.count, state.playbackState == .playing)
        }
        guard epoch == playbackEpoch, !Task.isCancelled else { return }
        let snapshot = NowPlayingSnapshot(
            title: song.title,
            artist: song.artist,
            album: song.albumName,
            duration: duration,
            position: engineProgress(),
            playbackRate: nowPlayingState.2 ? 1.0 : 0,
            artworkURL: artworkURL,
            artworkHeaders: artworkHeaders,
            coverArtId: song.effectiveCoverArtId,
            albumId: song.albumId,
            isLiveStream: false,
            radioStationName: nil,
            isrc: cachedISRC(for: song),
            trackId: song.id,
            queueIndex: nowPlayingState.0,
            queueCount: nowPlayingState.1
        )
        await nowPlayingService?.publishTrackChange(snapshot)
        guard epoch == playbackEpoch, !Task.isCancelled else { return }
        await nowPlayingService?.update(with: snapshot)
        guard epoch == playbackEpoch, !Task.isCancelled else { return }
        // Never background-cache Dolby/Atmos — lossy cache formats stereo-downmix the bitstream.
        // Also skip competing downloads on wireless system routes where bandwidth/route churn hurts playback.
        let skipEphemeralCache: Bool = {
            if AudioQualityClassifier.shouldBypassEphemeralCache(song) { return true }
            #if os(iOS)
            return PlayerService.isWirelessSystemRouteActive()
            #else
            return false
            #endif
        }()
        if case .stream(let streamURL, let customHeaders, let jellyfinContext, _) = source,
           jellyfinContext == nil,
           !skipEphemeralCache {
            let cacheFormat = await MainActor.run { cacheSettings.cacheFormat }

            let cacheStreamURL: URL?
            if cacheFormat == .matchStream {
                cacheStreamURL = streamURL
            } else if cacheFormat == .flacOriginal {
                cacheStreamURL = (try? await serverService.makeSwiftSonicClient())?.streamURL(
                    id: songId,
                    maxBitRate: nil,
                    format: "raw"
                )
            } else {
                // Lossy cache formats — fine for stereo/AAC sources only.
                cacheStreamURL = (try? await serverService.makeSwiftSonicClient())?.streamURL(
                    id: songId,
                    maxBitRate: cacheFormat.subsonicMaxBitRate,
                    format: cacheFormat.subsonicFormat
                )
            }

            guard epoch == playbackEpoch, !Task.isCancelled else { return }
            if let cacheStreamURL {
                cacheDownloadTask = Task { [cacheService, downloadService, serverService, cacheSession, weak self] in
                    try? await Task.sleep(for: .seconds(30))
                    guard !Task.isCancelled, let self else { return }
                    if await cacheService.cachedURL(forSongId: songId, serverId: serverId) != nil { return }
                    if await downloadService.isDownloaded(songId: songId, serverId: serverId) { return }
                    if await downloadService.isDownloading(songId: songId, serverId: serverId) { return }
                    let isLimited = await MainActor.run { serverService.state.isLimitedNetwork }
                    let isStillPlaying = await MainActor.run {
                        self.state.currentTrack?.id == songId && self.state.playbackState == .playing
                    }
                    guard !Task.isCancelled, isStillPlaying else { return }
                    if isLimited {
                        Logger.player.debug("Cache skipped — limited network for '\(songId, privacy: .public)'")
                        return
                    }
                    do {
                        try await self.downloadAndCache(
                            songId: songId,
                            serverId: serverId,
                            streamURL: cacheStreamURL,
                            customHeaders: customHeaders,
                            using: cacheSession
                        )
                    } catch {
                        Logger.player.debug("Cache download failed for '\(songId, privacy: .public)': \(error, privacy: .public)")
                    }
                }
            } else {
                Logger.player.debug("Cache: no URL for '\(songId, privacy: .public)' in \(cacheFormat.rawValue) — skipping")
            }
        } else if skipEphemeralCache {
            Logger.player.info("[SPATIAL] Skipping ephemeral cache for Dolby/multichannel '\(songId, privacy: .public)'")
        }

        await scheduleAutomaticDownload(song: song, serverId: serverId)
        guard epoch == playbackEpoch, !Task.isCancelled else { return }
        await ensureGaplessPreparation()
        guard epoch == playbackEpoch, !Task.isCancelled else { return }

        Task.detached { [weak self] in
            await self?.resolveAndPublishISRC(for: song)
        }
        await saveSession()
        startPositionSaveTimer()
        preloadNextTrackArtwork()
        await evaluateAutoExtend()
        // Single widget entry on track start — onPlayStateChanged would redo cover/color work.
        if let ws = widgetSyncService {
            Task { await ws.onTrackStarted(song) }
        }
        await reportOpenSubsonicPlayback(state: .playing, songId: song.id, positionMs: 0)
    }

    /// Warm all presentation data that normally opens HTTP requests as the track begins.
    /// Missing artwork or lyrics is a valid result, so either request may fail without making
    /// an otherwise playable song unavailable.
    private func preparePresentationAssets(for song: DisplayableSong, serverId: UUID) async {
        let artId = song.effectiveCoverArtId
        async let artwork = artworkImageCache.load(coverArtId: artId, tier: .hero)
        async let lyrics = try? lyricsService.fetchLyrics(
            forSongId: song.id,
            serverId: serverId,
            match: LyricsMatchInfo(song: song)
        )
        _ = await artwork
        _ = await lyrics
        Logger.player.debug("[PREPARE] artwork and lyrics settled for '\(song.title, privacy: .public)'")
    }
}
