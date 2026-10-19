import Foundation
import OSLog

extension PlayerService {
    func permitsNewTransportCommand() async -> Bool {
        guard stopBarrierCount == 0, !Task.isCancelled else { return false }
        let signingOut = await MainActor.run { serverService.state.isSigningOut }
        return !signingOut && stopBarrierCount == 0 && !Task.isCancelled
    }

    var playbackContext: PlaybackContext { authority.snapshot }

    func contextIsCurrent(_ context: PlaybackContext) -> Bool {
        context == playbackContext && !Task.isCancelled
    }

    /// The only projection boundary used by asynchronous transport confirmations and failures.
    @discardableResult
    func commitPresentation(_ context: PlaybackContext,
                            _ update: @MainActor @Sendable (PlayerState) -> Bool) async -> Bool {
        guard context == playbackContext else { return false }
        let applied = await MainActor.run {
            authority.commit(ifCurrent: context) { update(state) } ?? false
        }
        return applied && context == playbackContext
    }

    /// Invalidate pending work before suspending. Session interruptions use this without
    /// clearing the user's pre-interruption intention, unlike an explicit pause command.
    func cancelPendingTransportWork() {
        playbackRequestTask?.cancel()
        playbackRequestTask = nil
        playbackAcquisitionTask?.cancel()
        playbackAcquisitionTask = nil
        seekRequestGeneration &+= 1
        seekCommitTask?.cancel(); seekCommitTask = nil
        seekSettlementTask?.cancel(); seekSettlementTask = nil
        seekDownloadTask?.cancel(); seekDownloadTask = nil
        cancelAutoExtendFetch()
        restorePauseTask?.cancel(); restorePauseTask = nil
    }

    /// Stop unresolved commands immediately even when the platform delays the hard pause
    /// briefly to coalesce a screenshot interruption.
    @discardableResult
    func beginSystemInterruption() -> PlaybackContext {
        transport.interrupted = true
        transportCommandID &+= 1
        cancelPendingTransportWork()
        finalizePlaySegment()
        return playbackContext
    }

    /// An interruption need not deliver an `.ended` notification. A new user play
    /// command is allowed to reactivate the session; automatic queue work is not.
    func clearInterruptionForExplicitPlayback() {
        if transport.interrupted {
            Logger.player.notice("[INTERRUPTION] explicit play clears the interrupted transport")
        }
        transport.interrupted = false
        #if os(iOS)
        audioInterruptionActive = false
        interruptedWhilePlaying = false
        hardPausedForCurrentInterruption = false
        interruptionWasRouteDisconnect = false
        pendingScreenshotResume = false
        screenshotNotedAt = nil
        deferredInterruptionPauseTask?.cancel()
        deferredInterruptionPauseTask = nil
        #endif
    }

    /// Terminal failures keep the current selection and position available for explicit retry.
    /// Duplicated engine error callbacks cannot restart cleanup or a listening segment.
    func finishPlaybackFailure(_ error: CassetteError, context: PlaybackContext,
                               position: TimeInterval? = nil) async {
        guard contextIsCurrent(context), transport.terminalContext != context else { return }
        transport.terminalContext = context
        finalizePlaySegment()
        // Do not cancel the task that is committing its own failure until the UI is committed.
        let progress = progressTask
        progressTask = nil
        let acquisition = playbackAcquisitionTask
        playbackAcquisitionTask = nil
        cancelPendingScrobble()
        cancelPendingCacheDownload()
        cancelPendingPrefetch()
        cancelFadeTasks()
        cancelGaplessBridge()
        cancelAutoExtendFetch()
        stopPositionSaveTimer()
        nowPlayingEpoch &+= 1
        let retainedPosition = position ?? engineProgress()
        stopEngine()
        isTrackTransitionPending = false
        seekState = .idle
        seekNeedsCommit = false
        pendingRestoreInfo = (retainedPosition.isFinite ? max(0, retainedPosition) : 0, false)
        let committed = await commitPresentation(context) { state in
            if let position, position.isFinite { state.position = max(0, position) }
            state.pendingSeekPosition = nil
            state.playbackState = .error(error)
            return true
        }
        // A progress task can report a terminal reset itself. Cancel it after the commit.
        progress?.cancel()
        acquisition?.cancel()
        guard committed, context == playbackContext else { return }
        await nowPlayingService?.setPlaybackRate(0, publication: makePlaybackPublication())
        guard context == playbackContext else { return }
        await saveSession()
        guard context == playbackContext else { return }
        await publishWidgetStatus()
    }
    /// External status follows committed transport state; callers never guess an optimistic rate.
    func publishWidgetStatus(recordTrackStart: Bool = false) async {
        guard let widgetSyncService else { return }
        let publication = makePlaybackPublication()
        let snapshot = await MainActor.run { (state.currentTrack, state.playbackState == .playing) }
        guard publication.isCurrent else { return }
        if recordTrackStart, let track = snapshot.0 {
            await widgetSyncService.onTrackStarted(track, isPlaying: snapshot.1, publication: publication)
        } else {
            await widgetSyncService.onPlayStateChanged(isPlaying: snapshot.1, currentSong: snapshot.0, publication: publication)
        }
    }
    /// Rebuilds audio resources while retaining the user's queue. Apple requires a fresh
    /// user command after a media-services reset; the reset itself never starts playback.
    func resetAudioObjectsAfterMediaServicesReset() async {
        transportCommandID &+= 1
        playbackEpoch &+= 1
        let context = playbackContext
        let enginePosition = engineProgress()
        transport.intent = .pause
        transport.interrupted = false
        cancelPendingTransportWork()
        finalizePlaySegment()
        cancelPendingScrobble()
        cancelPendingCacheDownload()
        cancelPendingPrefetch()
        cancelGaplessBridge()
        cancelFadeTasks()
        stopProgressTimer()
        stopPositionSaveTimer()
        nowPlayingEpoch &+= 1
        stopEngine()
        systemEngine.stop()
        engine.resetAfterMediaServicesReset()
        isTrackTransitionPending = false
        let previous = audioObjectsResetTask
        let gain = replayGainService
        let graph = audioGraph
        let task = Task<Void, Never> {
            await previous?.value
            await gain?.resetAfterMediaServicesReset(graph: graph)
        }
        audioObjectsResetTask = task
        await task.value
        guard context == playbackContext else { return }
        audioObjectsResetTask = nil
        let retained = await MainActor.run { max(state.position, enginePosition) }
        guard context == playbackContext else { return }
        pendingRestoreInfo = (retained, true)
        seekState = .idle
        seekNeedsCommit = false
        guard await commitPresentation(context, { state in
            state.position = retained
            state.pendingSeekPosition = nil
            state.playbackState = state.currentTrack == nil && state.currentRadio == nil ? .idle : .paused
            return true
        }) else { return }
        await nowPlayingService?.setPlaybackRate(0, publication: makePlaybackPublication())
        guard context == playbackContext else { return }
        await saveSession()
        await publishWidgetStatus()
    }

}
