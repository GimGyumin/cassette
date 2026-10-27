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
        guard stopBarrierCount == 0 else { return }
        transport.intent = .pause
        #if os(iOS)
        sessionActivationRetryTask?.cancel()
        sessionActivationRetryTask = nil
        #endif
        cancelQualityUpgrade()
        transportCommandID &+= 1
        let commandID = transportCommandID
        let deferredSeekTarget = seekNeedsCommit ? seekState.target : nil
        let deferredReopensSource = seekCommitReopensSource
        seekRequestGeneration &+= 1
        let pauseRequest = seekRequestGeneration
        let pauseEpoch = playbackEpoch
        seekCommitTask?.cancel()
        seekCommitTask = nil
        seekSettlementTask?.cancel()
        seekSettlementTask = nil
        seekDownloadTask?.cancel()
        seekDownloadTask = nil
        seekRecoveryRequest = nil
        seekRecoveryInFlight = nil
        if let info = pendingRestoreInfo { pendingRestoreInfo = (seekTime: info.seekTime, pause: true) }
        playbackRequestTask?.cancel()
        playbackAcquisitionTask?.cancel()
        playbackAcquisitionTask = nil
        if isTrackTransitionPending {
            playbackEpoch &+= 1
            isTrackTransitionPending = false
            // Fresh selections already cleared their source before resolving. A recovery
            // may have a valid replacement and retained seek; keep those for the next resume.
        }
        cancelFadeTasks()
        finalizePlaySegment()
        // Stop timer first so a mid-flight rate=1 Now Playing push can't re-arm Music Haptics.
        stopProgressTimer()
        nowPlayingEpoch &+= 1
        pauseEngine()
        let context = playbackContext
        await nowPlayingService?.setPlaybackRate(0, publication: makePlaybackPublication())
        guard commandID == transportCommandID else { return }
        #if os(iOS)
        interruptedWhilePlaying = false
        pendingScreenshotResume = false
        screenshotNotedAt = nil
        deferredInterruptionPauseTask?.cancel()
        deferredInterruptionPauseTask = nil
        hardPausedForCurrentInterruption = false
        sessionActivationRetryTask?.cancel()
        sessionActivationRetryTask = nil
        // Keep the playback session active while paused. Deactivating it with
        // `.notifyOthersOnDeactivation` tells an interrupted app (for example Apple
        // Music) that it may resume, so pausing Cassette started the other app again.
        // Stop/end-of-queue also retain the session; system interruptions own handoff.
        #endif
        guard await commitPresentation(context, { $0.playbackState = .paused; return true }) else { return }
        guard commandID == transportCommandID else { return }
        if let target = deferredSeekTarget {
            await commitSeek(target: target, reopensSource: deferredReopensSource, epoch: pauseEpoch,
                             request: pauseRequest, intendsToPlay: false)
        } else if let target = seekState.target, !systemPlayback.isActive || systemEngine.hasCurrentItem {
            scheduleSeekSettlement(target: target, epoch: pauseEpoch, request: pauseRequest)
        }
        await pushPositionSnapshot(rate: 0.0)
        stopPositionSaveTimer()
        await saveSession()
        let pauseTrack = await MainActor.run { state.currentTrack }
        await publishWidgetStatus()
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
        let expected = playbackContext
        guard await permitsNewTransportCommand(), contextIsCurrent(expected), stopBarrierCount == 0 else { return }
        let hasSelection = await MainActor.run { state.currentTrack != nil }
        guard hasSelection, contextIsCurrent(expected), stopBarrierCount == 0 else { return }
        clearInterruptionForExplicitPlayback()
        transport.intent = .play
        transport.terminalContext = nil
        guard !transport.interrupted else { return }
        transportCommandID &+= 1
        let commandID = transportCommandID
        let context = playbackContext
        let epoch = playbackEpoch
        await audioObjectsResetTask?.value
        guard contextIsCurrent(context) else { return }
        restorePauseTask?.cancel()
        restorePauseTask = nil
        if isMutedForRestore {
            setEngineVolume(restoredVolume)
            isMutedForRestore = false
        }
        isRestoringSession = false
        let (currentTrack, queue, currentIndex, savedPosition) = await MainActor.run {
            (state.currentTrack, state.queue, state.currentIndex, state.position)
        }
        guard currentTrack != nil, commandID == transportCommandID,
              epoch == playbackEpoch, !Task.isCancelled else { return }
        if let target = seekState.target, seekNeedsCommit {
            let reopensSource = seekCommitReopensSource
            seekCommitTask?.cancel()
            seekCommitTask = nil
            seekRequestGeneration &+= 1
            await commitSeek(target: target, reopensSource: reopensSource, epoch: playbackEpoch,
                             request: seekRequestGeneration, intendsToPlay: true)
        }
        guard commandID == transportCommandID, epoch == playbackEpoch, !Task.isCancelled else { return }
        #if os(iOS)
        configureAudioSessionIfNeeded(preferMultichannel: systemPlayback.isActive)
        #endif
        if trackPlayStartDate == nil { trackPlayStartDate = Date() }

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

        var resolvedSourceOnResume = false
        if currentSource == nil, let track = currentTrack {
            // Restore publishes the selection before resolving its source. A play tap can
            // supersede that resolve, or retry a failed one, without losing the checkpoint.
            guard await commitPresentation(context, { state in
                state.playbackState = state.playbackState.resuming(reopensSource: true, position: savedPosition)
                return true
            }) else { return }
            guard let serverID = await MainActor.run(body: { serverService.state.activeServer?.id }),
                  contextIsCurrent(context) else {
                await finishPlaybackFailure(.serverNotConfigured, context: context, position: savedPosition)
                return
            }
            do {
                let source = try await mediaResolver.resolve(songId: track.id, serverId: serverID, song: track)
                guard contextIsCurrent(context) else { return }
                currentSource = source
                resolvedSourceOnResume = true
                pendingRestoreInfo = (seekTime: savedPosition, pause: false)
                guard await commitPresentation(context, { state in
                    state.isPlaybackAvailable = true
                    state.currentPlaybackTrack = source.playbackSong
                    return true
                }) else { return }
            } catch {
                guard contextIsCurrent(context) else { return }
                await finishPlaybackFailure(.playbackFailed(PlaybackFailure.classify(error)), context: context, position: savedPosition)
                return
            }
        }
        // A restored source has never been opened, even if an earlier pause changed the
        // empty engine's state to `.paused`. Explicit play must also consume pause-on-restore.
        let hasPendingRestore = pendingRestoreInfo != nil
        if let info = pendingRestoreInfo { pendingRestoreInfo = (seekTime: info.seekTime, pause: false) }

        // A resume that has to open the stream again (no current item, or an engine that is not
        // holding the track any more) is a *start*, not a resume: it stays `.loading` until an
        // engine confirms audio, exactly like a fresh play.
        let gainConfig = await MainActor.run { replayGainSettings.config }
        await applyReplayGain(track: currentSource?.playbackSong ?? currentTrack, config: gainConfig, context: context)
        guard contextIsCurrent(context) else { return }
        var startsFromColdSource = false
        if systemPlayback.isActive {
            if hasPendingRestore || !systemEngine.hasCurrentItem || systemEngine.state == .error, let source = currentSource {
                startsFromColdSource = true
                let resumePosition = pendingRestoreInfo?.seekTime ?? max(savedPosition, engineProgress())
                guard await commitPresentation(context, { state in
                    state.playbackState = state.playbackState.resuming(reopensSource: true, position: resumePosition)
                    return true
                }) else { return }
                guard commandID == transportCommandID, epoch == playbackEpoch, !Task.isCancelled else { return }
                let freshSource = resolvedSourceOnResume ? source : (await refreshedColdStartSource() ?? source)
                guard commandID == transportCommandID, epoch == playbackEpoch, !Task.isCancelled else { return }
                prepareColdResume(at: resumePosition)
                currentSource = freshSource
                guard await commitPresentation(context, { state in state.currentPlaybackTrack = freshSource.playbackSong; return true }) else { return }
                startEnginePlayback(
                    url: freshSource.url,
                    headers: freshSource.customHeaders,
                    useSystemPlayer: true
                )
            } else {
                systemEngine.resume()
            }
        } else if let source = currentSource,
                  hasPendingRestore || engine.state == .ready || engine.state == .stopped || engine.state == .error || engine.state == .disposed {
            startsFromColdSource = true
            // Session restore leaves the engine stopped with a pending seek — must play(url),
            // not resume(), or AudioStreaming can sit dead / hang the UI.
            let resumePosition = pendingRestoreInfo?.seekTime ?? max(savedPosition, engineProgress())
            guard await commitPresentation(context, { state in
                state.playbackState = state.playbackState.resuming(reopensSource: true, position: resumePosition)
                return true
            }) else { return }
            guard commandID == transportCommandID, epoch == playbackEpoch, !Task.isCancelled else { return }
            // A cold-start restore can hold a stale stream URL (expired auth token). Re-resolve
            // like the AVPlayer branch above, falling back to the in-memory source on failure.
            let freshSource = resolvedSourceOnResume ? source : (await refreshedColdStartSource() ?? source)
            guard commandID == transportCommandID, epoch == playbackEpoch, !Task.isCancelled else { return }
            prepareColdResume(at: resumePosition)
            currentSource = freshSource
            guard await commitPresentation(context, { state in state.currentPlaybackTrack = freshSource.playbackSong; return true }) else { return }
            startEnginePlayback(url: freshSource.url, headers: freshSource.customHeaders,
                                useSystemPlayer: resumePosition > 0 || currentTrack.map {
                                    shouldUseSystemPlayer(for: $0, source: freshSource)
                                } == true)
            Task { @MainActor in PlaybackBeatMeter.shared.setEnabled(true) }
        } else {
            engine.resume()
            if !systemPlayback.isActive {
                Task { @MainActor in PlaybackBeatMeter.shared.setEnabled(true) }
            }
        }
        // Never downgrade a state an engine has already confirmed.
        let publishedState = await MainActor.run { state.playbackState }
        guard commandID == transportCommandID, epoch == playbackEpoch, !Task.isCancelled else { return }
        // Opening the stream again stays `.loading` until an engine confirms audio: publishing
        // `.playing` for it is what made the transport show its pause/stop control while the stream
        // was still loading. A resume that lands on top of a start that is still in flight
        // (`.loading`) keeps waiting for the same reason.
        let isReopeningStream = startsFromColdSource || publishedState.isAwaitingAudio
        let reopensSource = startsFromColdSource
        if publishedState != .playing {
            guard await commitPresentation(context, { state in
                state.playbackState = state.playbackState.resuming(
                    reopensSource: reopensSource, position: state.position)
                return true
            }) else { return }
        }
        let audible = !startsFromColdSource && activeEngine.state == .playing
        guard contextIsCurrent(context) else { return }
        if audible, currentPlaySegmentStart == nil { currentPlaySegmentStart = Date() }
        if !audible { finalizePlaySegment() }
        await pushPositionSnapshot(rate: audible ? 1.0 : 0.0)
        guard commandID == transportCommandID, epoch == playbackEpoch, !Task.isCancelled else { return }
        startProgressTimer()
        if let target = seekState.target {
            scheduleSeekSettlement(target: target, epoch: playbackEpoch, request: seekRequestGeneration)
        }
        if isReopeningStream,
           let recoveryTrack = currentTrack,
           let serverId = await MainActor.run(body: { serverService.state.activeServer?.id }) {
            let recoveryPosition = await MainActor.run { state.position }
            guard commandID == transportCommandID, epoch == playbackEpoch, !Task.isCancelled else { return }
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
        guard commandID == transportCommandID, epoch == playbackEpoch, !Task.isCancelled else { return }
        startPositionSaveTimer()
        let resumeTrack = await MainActor.run { state.currentTrack }
        await publishWidgetStatus()
        if let id = resumeTrack?.id {
            let posMs = Int((await MainActor.run { state.position }) * 1000)
            await reportOpenSubsonicPlayback(state: .playing, songId: id, positionMs: posMs)
        }
        if let context = currentSource?.jellyfinPlaybackContext {
            let position = await MainActor.run { state.position }
            await reportJellyfinProgress(context, position: position, isPaused: false)
        }
    }

    private func prepareColdResume(at position: TimeInterval) {
        let position = position.isFinite ? max(0, position) : 0
        pendingRestoreInfo = (seekTime: position, pause: false)
        seekState = position > 0
            ? .settling(target: position, deadline: Date().addingTimeInterval(12)) : .idle
        lastObservedEngineProgress = position
        progressStallMonitor = PlaybackStallMonitor()
        seekRecoveryRequest = nil
        seekRecoveryInFlight = nil
        systemPlayback.resetTrackRecovery()
    }

    private func refreshedColdStartSource() async -> MediaSource? {
        if let source = currentSource, source.isLocal,
           FileManager.default.fileExists(atPath: source.url.path) { return source }
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
        stopBarrierCount += 1
        defer { stopBarrierCount -= 1 }
        cancelPendingTransportWork()
        isTrackTransitionPending = false
        transport.interrupted = false
        #if os(iOS)
        interruptedWhilePlaying = false
        audioInterruptionActive = false
        pendingScreenshotResume = false
        screenshotNotedAt = nil
        deferredInterruptionPauseTask?.cancel()
        deferredInterruptionPauseTask = nil
        hardPausedForCurrentInterruption = false
        interruptionWasRouteDisconnect = false
        #endif
        transport.intent = .stop
        transportCommandID &+= 1
        let commandID = transportCommandID
        let context = playbackContext
        cancelAutoExtendFetch()
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
        finalizePlaySegment()
        stopEngine()
        await recordCurrentTrackPlayback(trigger: "user_stopped")
        guard commandID == transportCommandID else { return }
        await nowPlayingService?.setPlaybackRate(0, publication: makePlaybackPublication())
        guard commandID == transportCommandID else { return }
        await nowPlayingService?.clearISRC()
        guard commandID == transportCommandID else { return }
        await nowPlayingService?.stop(publication: makePlaybackPublication())
        guard commandID == transportCommandID else { return }
        restorePauseTask?.cancel()
        restorePauseTask = nil
        if isMutedForRestore {
            setEngineVolume(restoredVolume)
            isMutedForRestore = false
        }
        liveStreamStallTask?.cancel()
        liveStreamStallTask = nil
        #if os(iOS)
        sessionActivationRetryTask?.cancel()
        sessionActivationRetryTask = nil
        // Do NOT call setActive(false) here. Even without .notifyOthersOnDeactivation,
        // deactivating the session signals other audio apps (e.g. Apple Music) that
        // they may resume — which caused Apple Music to start playing when Cassette stopped.
        // The session is retained while the app is alive and releases naturally when the
        // process exits or the system reclaims it.
        #endif
        accumulatedPlayedSeconds = 0
        currentPlaySegmentStart = nil
        trackPlayStartDate = nil
        resolvedISRCForCurrentTrack = nil
        resolvedISRCSongId = nil
        await applyReplayGain(track: nil, config: ReplayGainConfig(enabled: false, mode: .track, preAmp: 0, preventClipping: true),
                              context: PlaybackContext(command: commandID, epoch: context.epoch &+ 1))
        guard commandID == transportCommandID else { return }
        let stoppedPlaybackID = currentSource?.playbackSong?.id
        let stoppedJellyfinContext = currentSource?.jellyfinPlaybackContext
        currentSource = nil
        pendingRestoreInfo = nil
        seekState = .idle
        seekNeedsCommit = false
        isRestoringSession = false
        let visibleStoppedID = await MainActor.run { state.currentTrack?.id }
        let stoppedId = stoppedPlaybackID ?? visibleStoppedID
        let stoppedPos = await MainActor.run { state.position }
        gaplessBridge.clearPreparedSource()
        guard await commitPresentation(PlaybackContext(command: commandID, epoch: context.epoch &+ 1), { state in
            state.playbackState = .idle
            state.currentTrack = nil
            state.currentPlaybackTrack = nil
            state.currentRadio = nil
            state.isSmartShuffleActive = false
            state.originalQueueEndIndex = nil
            state.queue = []
            state.position = 0
            state.pendingSeekPosition = nil
            state.duration = 0
            state.isSeekable = false
            state.isDeliveringTranscodedAudio = false
            return true
        }) else { return }
        await publishWidgetStatus()
        guard commandID == transportCommandID else { return }
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
        guard stopBarrierCount == 0 else { return }
        let resetContext = playbackContext
        let epoch = playbackEpoch
        await audioObjectsResetTask?.value
        guard contextIsCurrent(resetContext) else { return }
        guard !Task.isCancelled, position.isFinite else {
            Logger.player.warning("seek ignored — non-finite target")
            return
        }
        seekRequestGeneration &+= 1
        let request = seekRequestGeneration
        seekRecoveryRequest = nil
        seekRecoveryInFlight = nil
        let playback = await MainActor.run {
            (isLiveStream: state.isLiveStream,
             hasTrack: state.currentTrack != nil,
             duration: state.duration,
             previousPosition: state.position,
             intendsToPlay: state.playbackState.hasPlaybackIntent)
        }
        guard contextIsCurrent(resetContext), epoch == playbackEpoch, request == seekRequestGeneration,
              !Task.isCancelled, !isTrackTransitionPending else { return }
        guard !playback.isLiveStream else {
            Logger.player.debug("seek ignored — live stream mode")
            return
        }
        guard playback.hasTrack, playback.duration > 0 else {
            Logger.player.debug("seek ignored — no playable duration")
            return
        }
        // An encoder opened exactly at EOF can answer with empty audio. Leave a short final
        // interval; natural EOF still completes playback once this seek has actually landed.
        let target = max(0, min(position, max(0, playback.duration - 0.25)))
        // Accept early requests with catalog duration even before the parser opens.
        // The cold-parser path below retains the target in a native-player restore.
        let canAcceptSeek = engineIsSeekable()
            || (currentSource != nil && currentSource?.isLiveStream == false)
        guard canAcceptSeek else {
            await MainActor.run {
                state.isSeekable = false
                state.position = playback.previousPosition
            }
            Logger.player.warning("seek ignored — active format/engine is not seekable")
            return
        }
        // A rejected scrub during track resolution must not invalidate the play command.
        transportCommandID &+= 1
        let context = playbackContext
        seekDownloadTask?.cancel()
        cancelQualityUpgrade()
        seekDownloadTask = nil
        seekCommitTask?.cancel()
        seekCommitTask = nil
        seekSettlementTask?.cancel()
        seekSettlementTask = nil
        nowPlayingEpoch &+= 1
        cancelFadeTasks()
        if currentPlaySegmentStart != nil {
            finalizePlaySegment()
        }
        // Flush both the engine entry and its metadata together. The progress loop re-arms
        // the successor once the seek settles; an AVQueuePlayer item must not outlive its bridge.
        cancelGaplessBridge()
        // A tick captured before this scrub must not publish the previous stream's clock
        // or interpret its reset as EOF after we reopen the encoder.
        stopProgressTimer()
        restorePauseTask?.cancel()
        restorePauseTask = nil
        endOfTrackStallStartedAt = nil
        progressStallMonitor = PlaybackStallMonitor()
        systemPlayback.resetTrackRecovery()

        // Arm settling before the MainActor hop below. Actor reentrancy would otherwise let
        // the progress task publish one stale pre-seek sample in between.
        seekState = .settling(target: target, deadline: Date().addingTimeInterval(30))
        // Give the refetch from the new offset room to finish before the stall watchdogs may fire.
        systemPlayback.seekSettleDeadline = Date().addingTimeInterval(10)
        // The next end-of-track sample must be compared with the requested position, not the
        // pre-seek position; otherwise a legitimate backward seek looks like an EOF wrap.
        lastObservedEngineProgress = target
        let relativeTarget = target - streamTimeOffset
        let hasBufferedTarget = systemPlayback.isActive && systemEngine.canSeekInBufferedRange(to: relativeTarget)
        let nativeUniversal = currentSource?.isJellyfinUniversal == true && streamTimeOffset == 0
            && systemPlayback.isActive && systemEngine.isSeekable
        let reopensSource = (currentSource?.supportsTranscodeOffset == true && !hasBufferedTarget && !nativeUniversal)
            || (!systemPlayback.isActive && currentSource != nil && !activeEngine.isSeekable)
            || (systemPlayback.isActive && !systemEngine.hasCurrentItem && currentSource != nil)
        seekNeedsCommit = true
        seekCommitReopensSource = reopensSource
        guard await commitPresentation(context, { state in
            state.position = target
            state.pendingSeekPosition = target
            state.isSeekable = true
            if playback.intendsToPlay { state.playbackState = .recovering }
            return true
        }) else { return }
        guard epoch == playbackEpoch, request == seekRequestGeneration, !Task.isCancelled else { return }
        // Pause interpolation/Music Haptics while the requested timeline is not producing audio.
        await pushPositionSnapshot(rate: 0)
        guard epoch == playbackEpoch, request == seekRequestGeneration, !Task.isCancelled else { return }
        if (reopensSource && currentSource?.supportsTranscodeOffset == true) || currentSource?.isLocal == true {
            // Coalesce releases in a quick sequence; drag samples never reach this path.
            let delay: Duration = currentSource?.isLocal == true ? .milliseconds(60) : .milliseconds(120)
            let commit = Task { [weak self] in
                do { try await Task.sleep(for: delay) } catch { return }
                await self?.commitSeek(target: target, reopensSource: reopensSource, epoch: epoch,
                                       request: request, intendsToPlay: playback.intendsToPlay)
            }
            seekCommitTask = commit
            await commit.value
        } else {
            await commitSeek(target: target, reopensSource: reopensSource, epoch: epoch,
                             request: request, intendsToPlay: playback.intendsToPlay)
        }
    }

    // MARK: - Skip

    func skipToNext() async throws {
        let command = transportCommandID
        let epoch = playbackEpoch
        guard await MainActor.run(body: { !state.isLiveStream }) else {
            Logger.player.debug("skipToNext ignored — live stream mode")
            return
        }
        let (queue, currentIndex, repeatMode) = await MainActor.run {
            (state.queue, state.currentIndex, state.repeatMode)
        }
        guard command == transportCommandID, epoch == playbackEpoch, !Task.isCancelled else { return }
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
            guard command == transportCommandID, epoch == playbackEpoch, !Task.isCancelled else { return }
            await pauseAtEndOfQueue()
        }
    }

    /// When the planned queue is exhausted, pick similar library tracks and keep playing.
    @discardableResult
    private func continueWithSimilarTracksAfterQueueEnd() async -> Bool {
        let epoch = playbackEpoch
        let command = transportCommandID
        let snapshot = await MainActor.run {
            (state.isAutoExtendEnabled, state.repeatMode, state.isLiveStream,
             state.queue, state.currentIndex, serverService.state.activeServer?.id)
        }
        guard Self.allowsAutoExtend(enabled: snapshot.0, repeatMode: snapshot.1, isLive: snapshot.2),
              epoch == playbackEpoch, command == transportCommandID, !Task.isCancelled else { return false }
        do {
            let tracks = try await libraryService.similarBackfillQueue(targetSize: 40, excludedIds: Set(snapshot.3.map(\.id)))
            guard epoch == playbackEpoch, command == transportCommandID, !Task.isCancelled else { return false }
            let queue = await MainActor.run { () -> [DisplayableSong]? in
                guard !Task.isCancelled, state.queue == snapshot.3, state.currentIndex == snapshot.4,
                      serverService.state.activeServer?.id == snapshot.5,
                      Self.allowsAutoExtend(enabled: state.isAutoExtendEnabled, repeatMode: state.repeatMode,
                                            isLive: state.isLiveStream) else { return nil }
                var ids = Set(state.queue.map(\.id))
                let additions = tracks.filter { ids.insert($0.id).inserted }
                guard !additions.isEmpty else { return nil }
                return state.queue + additions
            }
            guard let queue, epoch == playbackEpoch, command == transportCommandID else { return false }
            try await play(tracks: queue, startIndex: snapshot.3.count, preservePlayingState: true)
            guard transportCommandID == command &+ 1, !Task.isCancelled else { return true }
            await MainActor.run {
                if state.queue == queue, state.currentIndex == snapshot.3.count {
                    state.originalQueueEndIndex = snapshot.3.count
                }
            }
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
