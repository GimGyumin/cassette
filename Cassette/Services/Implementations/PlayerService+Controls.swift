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
    // MARK: - Pause / Resume

    func pause() async {
        playbackRequestTask?.cancel()
        playbackAcquisitionTask?.cancel()
        playbackAcquisitionTask = nil
        if isTrackTransitionPending {
            playbackEpoch &+= 1
            isTrackTransitionPending = false
            currentSource = nil
        }
        cancelFadeTasks()
        finalizePlaySegment()
        // Stop timer first so a mid-flight rate=1 Now Playing push can't re-arm Music Haptics.
        stopProgressTimer()
        nowPlayingEpoch &+= 1
        await nowPlayingService?.setPlaybackRate(0)
        pauseEngine()
        #if os(iOS)
        interruptedWhilePlaying = false
        pendingScreenshotResume = false
        screenshotNotedAt = nil
        deferredInterruptionPauseTask?.cancel()
        deferredInterruptionPauseTask = nil
        hardPausedForCurrentInterruption = false
        sessionActivationRetryTask?.cancel()
        sessionActivationRetryTask = nil
        // Keep the session hot on wireless routes — setActive(false) forces a slow re-handshake on resume.
        if !PlayerService.isWirelessSystemRouteActive() {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        #endif
        await MainActor.run { state.playbackState = .paused }
        await pushPositionSnapshot(rate: 0.0)
        stopPositionSaveTimer()
        await saveSession()
        let pauseTrack = await MainActor.run { state.currentTrack }
        if let ws = widgetSyncService {
            Task { [weak ws] in await ws?.onPlayStateChanged(isPlaying: false, currentSong: pauseTrack) }
        }
        if let id = pauseTrack?.id {
            let posMs = Int((await MainActor.run { state.position }) * 1000)
            await reportOpenSubsonicPlayback(state: .paused, songId: id, positionMs: posMs)
        }
        if let context = currentSource?.jellyfinPlaybackContext {
            let position = await MainActor.run { state.position }
            await reportJellyfinProgress(context, position: position, isPaused: true)
        }
    }

    func resume() async {
        restorePauseTask?.cancel()
        restorePauseTask = nil
        if isMutedForRestore {
            setEngineVolume(restoredVolume)
            isMutedForRestore = false
        }
        isRestoringSession = false
        let (currentTrack, queue, currentIndex) = await MainActor.run {
            (state.currentTrack, state.queue, state.currentIndex)
        }
        guard currentTrack != nil else { return }
        #if os(iOS)
        configureAudioSessionIfNeeded(preferMultichannel: systemPlayback.isActive)
        #endif
        if trackPlayStartDate == nil { trackPlayStartDate = Date() }
        if currentPlaySegmentStart == nil { currentPlaySegmentStart = Date() }

        if stoppedAtEndOfQueue {
            stoppedAtEndOfQueue = false
            pendingRestoreInfo = nil
            if !queue.isEmpty {
                // Restart from the track that was playing at end-of-queue, not always index 0.
                let restartIndex = min(max(0, currentIndex), queue.count - 1)
                try? await play(tracks: queue, startIndex: restartIndex)
                return
            }
        }

        guard currentSource != nil else {
            guard queue.indices.contains(currentIndex) else { return }
            try? await play(tracks: queue, startIndex: currentIndex)
            return
        }

        // A resume that has to open the stream again (no current item, or an engine that is not
        // holding the track any more) is a *start*, not a resume: it stays `.loading` until an
        // engine confirms audio, exactly like a fresh play.
        var startsFromColdSource = false
        if systemPlayback.isActive {
            if !systemEngine.hasCurrentItem, let source = currentSource {
                startsFromColdSource = true
                if let info = pendingRestoreInfo, info.pause {
                    pendingRestoreInfo = (seekTime: info.seekTime, pause: false)
                }
                let freshSource = await refreshedColdStartSource() ?? source
                currentSource = freshSource
                startEnginePlayback(
                    url: freshSource.url,
                    headers: freshSource.customHeaders,
                    useSystemPlayer: true
                )
            } else {
                systemEngine.resume()
            }
        } else if let source = currentSource,
                  engine.state == .ready || engine.state == .stopped || engine.state == .error {
            startsFromColdSource = true
            // Session restore leaves the engine stopped with a pending seek — must play(url),
            // not resume(), or AudioStreaming can sit dead / hang the UI.
            if let info = pendingRestoreInfo, info.pause {
                pendingRestoreInfo = (seekTime: info.seekTime, pause: false)
            }
            // A cold-start restore can hold a stale stream URL (expired auth token). Re-resolve
            // like the AVPlayer branch above, falling back to the in-memory source on failure.
            let freshSource = await refreshedColdStartSource() ?? source
            currentSource = freshSource
            startEnginePlayback(url: freshSource.url, headers: freshSource.customHeaders, useSystemPlayer: false)
            Task { @MainActor in PlaybackBeatMeter.shared.setEnabled(true) }
        } else {
            engine.resume()
            if !systemPlayback.isActive {
                Task { @MainActor in PlaybackBeatMeter.shared.setEnabled(true) }
            }
        }
        // Never downgrade a state an engine has already confirmed.
        let publishedState = await MainActor.run { state.playbackState }
        // Opening the stream again stays `.loading` until an engine confirms audio: publishing
        // `.playing` for it is what made the transport show its pause/stop control while the stream
        // was still loading. A resume that lands on top of a start that is still in flight
        // (`.loading`) keeps waiting for the same reason.
        let isReopeningStream = startsFromColdSource || publishedState.isAwaitingAudio
        let reopensSource = startsFromColdSource
        if publishedState != .playing {
            await MainActor.run {
                state.playbackState = state.playbackState.resuming(
                    reopensSource: reopensSource, position: state.position
                )
            }
        }
        if await MainActor.run(body: { state.playbackState.isAwaitingAudio }) {
            finalizePlaySegment()
        }
        await pushPositionSnapshot(rate: 1.0)
        startProgressTimer()
        if isReopeningStream,
           let recoveryTrack = currentTrack,
           let serverId = await MainActor.run(body: { serverService.state.activeServer?.id }) {
            let recoveryPosition = await MainActor.run { state.position }
            if startsFromColdSource, recoveryPosition > 0 {
                scheduleStallRecoveryCompletion(
                    songID: recoveryTrack.id, epoch: playbackEpoch, position: recoveryPosition
                )
            } else {
                schedulePlaybackAcquisitionRecovery(
                    song: recoveryTrack, serverId: serverId, epoch: playbackEpoch
                )
            }
        }
        startPositionSaveTimer()
        let resumeTrack = await MainActor.run { state.currentTrack }
        if let ws = widgetSyncService {
            Task { [weak ws] in await ws?.onPlayStateChanged(isPlaying: true, currentSong: resumeTrack) }
        }
        if let id = resumeTrack?.id {
            let posMs = Int((await MainActor.run { state.position }) * 1000)
            await reportOpenSubsonicPlayback(state: .playing, songId: id, positionMs: posMs)
        }
        if let context = currentSource?.jellyfinPlaybackContext {
            let position = await MainActor.run { state.position }
            await reportJellyfinProgress(context, position: position, isPaused: false)
        }
    }

    private func refreshedColdStartSource() async -> MediaSource? {
        guard let track = await MainActor.run(body: { state.currentTrack }),
              let serverId = await MainActor.run(body: { serverService.state.activeServer?.id }) else { return nil }
        do {
            return try await mediaResolver.resolve(songId: track.id, serverId: serverId, song: track)
        } catch {
            Logger.player.warning("[RESTORE] cold-start re-resolve failed: \(error, privacy: .public)")
            return nil
        }
    }

    func togglePlayPause() async {
        let hasPlayIntent = await MainActor.run {
            state.playbackState.hasPlaybackIntent
        }
        if hasPlayIntent { await pause() } else { await resume() }
    }

    // MARK: - Stop

    func stop() async {
        playbackRequestTask?.cancel()
        playbackAcquisitionTask?.cancel()
        playbackAcquisitionTask = nil
        cancelGaplessBridge()
        // Invalidate pending URL resolution and recovery before any suspension.
        playbackEpoch &+= 1
        cancelPendingScrobble()
        cancelPendingCacheDownload()
        cancelPendingPrefetch()
        cancelFadeTasks()
        musicHapticsNudgeTask?.cancel()
        musicHapticsNudgeTask = nil
        stopProgressTimer()
        stopPositionSaveTimer()
        nowPlayingEpoch &+= 1
        await nowPlayingService?.setPlaybackRate(0)
        await nowPlayingService?.clearISRC()
        await nowPlayingService?.stop()
        restorePauseTask?.cancel()
        restorePauseTask = nil
        if isMutedForRestore {
            setEngineVolume(restoredVolume)
            isMutedForRestore = false
        }
        liveStreamStallTask?.cancel()
        liveStreamStallTask = nil
        stopEngine()
        #if os(iOS)
        sessionActivationRetryTask?.cancel()
        sessionActivationRetryTask = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        accumulatedPlayedSeconds = 0
        currentPlaySegmentStart = nil
        trackPlayStartDate = nil
        resolvedISRCForCurrentTrack = nil
        resolvedISRCSongId = nil
        await replayGainService?.resetGain()
        let stoppedJellyfinContext = currentSource?.jellyfinPlaybackContext
        currentSource = nil
        pendingRestoreInfo = nil
        seekState = .idle
        isRestoringSession = false
        let stoppedId = await MainActor.run { state.currentTrack?.id }
        let stoppedPos = await MainActor.run { state.position }
        gaplessBridge.clearPreparedSource()
        await MainActor.run {
            state.playbackState = .idle
            state.currentTrack = nil
            state.currentRadio = nil
            state.isSmartShuffleActive = false
            state.originalQueueEndIndex = nil
            state.queue = []
            state.position = 0
            state.duration = 0
            state.isSeekable = false
            state.isDeliveringTranscodedAudio = false
        }
        if let stoppedId {
            await reportOpenSubsonicPlayback(
                state: .stopped,
                songId: stoppedId,
                positionMs: Int(stoppedPos * 1000)
            )
        }
        if let stoppedJellyfinContext {
            await reportJellyfinStopped(stoppedJellyfinContext, position: stoppedPos)
        }
    }

    // MARK: - Seek

    func seek(to position: TimeInterval) async {
        let epoch = playbackEpoch
        guard position.isFinite else {
            Logger.player.warning("seek ignored — non-finite target")
            return
        }
        let playback = await MainActor.run {
            (isLiveStream: state.isLiveStream,
             hasTrack: state.currentTrack != nil,
             duration: state.duration,
             previousPosition: state.position,
             intendsToPlay: state.playbackState.hasPlaybackIntent)
        }
        guard epoch == playbackEpoch, !isTrackTransitionPending else { return }
        guard !playback.isLiveStream else {
            Logger.player.debug("seek ignored — live stream mode")
            return
        }
        guard playback.hasTrack, playback.duration > 0 else {
            Logger.player.debug("seek ignored — no playable duration")
            return
        }
        let target = max(0, min(position, playback.duration))
        // AudioStreaming reports false during its initial parser window even for normal
        // MP3/AAC files. Its seek API retains the requested position while parsing, so a
        // catalog duration is enough to accept that early request. Once the engine has a
        // duration, its explicit format verdict (for example Ogg) remains authoritative.
        let engineDuration = engineDuration()
        let canAcceptSeek = engineIsSeekable()
            || (engineDuration <= 0 && playback.duration > 0 && currentSource != nil)
        guard canAcceptSeek else {
            await MainActor.run {
                state.isSeekable = false
                state.position = playback.previousPosition
            }
            Logger.player.warning("seek ignored — active format/engine is not seekable")
            return
        }
        cancelFadeTasks()
        if currentPlaySegmentStart != nil {
            finalizePlaySegment()
            currentPlaySegmentStart = Date()
        }
        // Flush both the engine entry and its metadata together. The progress loop re-arms
        // the successor once the seek settles; an AVQueuePlayer item must not outlive its bridge.
        cancelGaplessBridge()

        // Arm settling before the MainActor hop below. Actor reentrancy would otherwise let
        // the progress task publish one stale pre-seek sample in between.
        seekState = .settling(target: target, deadline: Date().addingTimeInterval(8))
        // Give the refetch from the new offset room to finish before the stall watchdogs may fire.
        systemPlayback.seekSettleDeadline = Date().addingTimeInterval(10)
        // The next end-of-track sample must be compared with the requested position, not the
        // pre-seek position; otherwise a legitimate backward seek looks like an EOF wrap.
        lastObservedEngineProgress = target
        if let source = currentSource, source.supportsTranscodeOffset {
            // Open a fresh encoder at the requested media time instead of issuing Range against
            // an unfinished file. Preserve an explicit pause and fence obsolete acquisition work.
            playbackAcquisitionTask?.cancel()
            playbackAcquisitionTask = nil
            cancelPendingCacheDownload()
            cancelPendingPrefetch()
            pendingRestoreInfo = (seekTime: target, pause: !playback.intendsToPlay)
            startEnginePlayback(url: source.url, headers: source.customHeaders,
                                useSystemPlayer: systemPlayback.isActive || !playback.intendsToPlay)
        } else {
            seekEngine(to: target)
        }
        await MainActor.run {
            state.position = target
            state.isSeekable = true
        }
        // Hold the scrubber at the seek target until the engine confirms that it landed.
        await pushPositionSnapshot()
    }

    // MARK: - Skip

    func skipToNext() async throws {
        guard await MainActor.run(body: { !state.isLiveStream }) else {
            Logger.player.debug("skipToNext ignored — live stream mode")
            return
        }
        let (queue, currentIndex, repeatMode) = await MainActor.run {
            (state.queue, state.currentIndex, state.repeatMode)
        }
        let nextIndex = currentIndex + 1
        Logger.player.info("[TRANSITION] skipToNext: currentIndex=\(currentIndex) nextIndex=\(nextIndex) queueCount=\(queue.count)")

        if nextIndex < queue.count {
            let next = queue[nextIndex]
            Logger.player.info("[TRANSITION] skipToNext → track id=\(next.id, privacy: .public) title=\(next.title, privacy: .public)")
            try await play(tracks: queue, startIndex: nextIndex, preservePlayingState: true)
        } else if repeatMode == .all {
            Logger.player.info("[TRANSITION] skipToNext → wrap-around (repeatAll), restarting queue from index 0")
            try await play(tracks: queue, startIndex: 0, preservePlayingState: true)
        } else if await continueWithSimilarTracksAfterQueueEnd() {
            Logger.player.info("[TRANSITION] skipToNext → auto-selected similar tracks after queue end")
        } else {
            await pauseAtEndOfQueue()
        }
    }

    /// When the planned queue is exhausted, pick similar library tracks and keep playing.
    @discardableResult
    private func continueWithSimilarTracksAfterQueueEnd() async -> Bool {
        let queueIds = await MainActor.run { Set(state.queue.map(\.id)) }
        do {
            let tracks = try await libraryService.similarBackfillQueue(targetSize: 40, excludedIds: queueIds)
            guard !tracks.isEmpty else { return false }
            await anchorOriginalQueueBoundaryIfNeeded()
            let startIndex = await MainActor.run { state.queue.count }
            await appendToQueue(tracks)
            let newQueue = await MainActor.run { state.queue }
            guard startIndex < newQueue.count else { return false }
            try await play(tracks: newQueue, startIndex: startIndex, preservePlayingState: true)
            // Keep auto-extend primed so the new tail stays topped up.
            await MainActor.run {
                if !state.isAutoExtendEnabled {
                    state.isAutoExtendEnabled = true
                }
            }
            UserDefaults.standard.set(true, forKey: Self.autoExtendUserDefaultsKey)
            await evaluateAutoExtend()
            return true
        } catch {
            Logger.player.debug("Queue-end auto-select failed: \(error, privacy: .public)")
            return false
        }
    }

    func skipToPrevious() async throws {
        guard await MainActor.run(body: { !state.isLiveStream }) else {
            Logger.player.debug("skipToPrevious ignored — live stream mode")
            return
        }
        let (queue, currentIndex, position) = await MainActor.run {
            (state.queue, state.currentIndex, state.position)
        }

        if position >= 3 || currentIndex == 0 {
            await seek(to: 0)
        } else {
            try await play(tracks: queue, startIndex: currentIndex - 1, preservePlayingState: true)
        }
    }
}
