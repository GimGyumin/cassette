import AudioStreaming
import Foundation
import SwiftSonic
import Testing
@testable import Cassette

/// Loading keeps the user's play intent visible without claiming audio has started.
/// A tap on the active control can cancel the pending request.
@Suite("Playback control appearance")
struct PlaybackControlAppearanceTests {
    @Test func waitsPreserveTheirReasonAndTransportIntent() {
        for state in [PlaybackState.loading, .buffering, .recovering] {
            #expect(state.isAwaitingAudio)
            #expect(state.hasPlaybackIntent)
            #expect(state.controlAppearance == .loading)
            #expect(state.waitingForAudio() == state)
            #expect(state.confirmingPlayback(restoringIntoPause: false) == .playing)
            #expect(state.confirmingPlayback(restoringIntoPause: true) == nil)
        }
        #expect(PlaybackState.playing.waitingForAudio() == .buffering)
        for state in [PlaybackState.idle, .paused, .error(.timeout)] {
            #expect(state.waitingForAudio() == nil)
            #expect(!state.hasPlaybackIntent)
        }
    }

    @Test func resumeDistinguishesInitialAcquisitionFromRecovery() {
        #expect(PlaybackState.paused.resuming(reopensSource: true, position: 0) == .loading)
        #expect(PlaybackState.paused.resuming(reopensSource: true, position: 42) == .recovering)
        #expect(PlaybackState.buffering.resuming(reopensSource: false, position: 42) == .buffering)
        #expect(PlaybackState.recovering.resuming(reopensSource: false, position: 42) == .recovering)
        #expect(PlaybackState.paused.resuming(reopensSource: false, position: 42) == .playing)
    }

    @Test func seekKeepsItsTargetThroughTemporaryZeroAndClearsAtomically() {
        let now = Date(timeIntervalSince1970: 100)
        var seek = PlaybackSeekState.settling(target: 60, deadline: now.addingTimeInterval(8))
        #expect(seek.reconcile(progress: 0, now: now) == .waiting(60))
        #expect(seek.target == 60)
        #expect(seek.reconcile(progress: 59, now: now.addingTimeInterval(1)) == .finished(target: 60, landed: true))
        #expect(seek == .idle)
        #expect(seek.target == nil)
        #expect(seek.reconcile(progress: 0, now: now) == .inactive)
        seek = .settling(target: 60, deadline: now)
        #expect(seek.reconcile(progress: 0, now: now) == .finished(target: 60, landed: false))
        #expect(seek == .idle)
    }

    // MARK: - What the control renders

    @Test func loadingKeepsActivePlaybackAppearance() {
        #expect(PlaybackState.loading.controlAppearance == .loading)
        #expect(PlaybackState.loading.controlAppearance.systemImage == "pause.fill")
        #expect(PlaybackState.loading.hasPlaybackIntent)
    }

    @Test func onlyConfirmedPlaybackRendersAsPause() {
        #expect(PlaybackState.playing.controlAppearance == .pause)
    }

    @Test func idlePausedAndErrorRenderAsPlay() {
        #expect(PlaybackState.idle.controlAppearance == .play)
        #expect(PlaybackState.paused.controlAppearance == .play)
        #expect(PlaybackState.error(.timeout).controlAppearance == .play)
        #expect(!PlaybackState.paused.hasPlaybackIntent)
    }

    // MARK: - What ends a `.loading` start

    @Test func engineConfirmationPromotesAPendingStart() {
        #expect(PlaybackState.loading.confirmingPlayback(restoringIntoPause: false) == PlaybackState.playing)
    }

    @Test func engineConfirmationNeverOverridesAUserPause() {
        #expect(PlaybackState.paused.confirmingPlayback(restoringIntoPause: false) == nil)
    }

    @Test func engineConfirmationIsIgnoredWhileAlreadyPlaying() {
        #expect(PlaybackState.playing.confirmingPlayback(restoringIntoPause: false) == nil)
    }

    @Test func engineConfirmationLeavesIdleAndErrorAlone() {
        #expect(PlaybackState.idle.confirmingPlayback(restoringIntoPause: false) == nil)
        #expect(PlaybackState.error(.timeout).confirmingPlayback(restoringIntoPause: false) == nil)
    }

    @Test func restoreIntoPauseIsNeverPromoted() {
        #expect(PlaybackState.loading.confirmingPlayback(restoringIntoPause: true) == nil)
    }
}

// MARK: - Resume: reopening a stream is a start, not playback

@MainActor
@Suite("Resume publishes audio, not optimism", .serialized)
struct ResumePlaybackStateTests {
    @Test func engineRebuildPublishesRecoveryAndPreservesPause() async throws {
        let container = try AppContainer(inMemory: true, engine: FakePlaybackEngine())
        let service = try #require(container.playerService as? PlayerService)
        container.playerState.position = 60
        container.playerState.playbackState = .playing
        let reopened = await service.publishEngineRecovery()
        #expect(reopened)
        #expect(container.playerState.playbackState == .recovering)
        await service.publishEnginePlaybackConfirmation()
        #expect(container.playerState.playbackState == .playing)
        await service.pause()
        let pausedReopen = await service.publishEngineRecovery()
        #expect(!pausedReopen)
        #expect(container.playerState.playbackState == .paused)
        await service.stop()
    }
    @Test func bufferingCallbacksCannotUndoAUserPause() async throws {
        let engine = FakePlaybackEngine()
        let container = try AppContainer(inMemory: true, engine: engine)
        let service = try #require(container.playerService as? PlayerService)
        container.playerState.playbackState = .loading
        engine.state = .bufferring
        await service.handleAudioStateChanged(.bufferring)
        #expect(container.playerState.playbackState == .loading)
        engine.state = .playing
        await service.handleAudioStateChanged(.playing)
        #expect(container.playerState.playbackState == .playing)
        await service.startSegmentForTest()
        engine.state = .bufferring
        await service.handleAudioStateChanged(.bufferring)
        #expect(container.playerState.playbackState == .buffering)
        let segmentWhileWaiting = await service.currentPlaySegmentStart
        #expect(segmentWhileWaiting == nil)
        engine.state = .playing
        await service.handleAudioStateChanged(.playing)
        let resumedSegment = await service.currentPlaySegmentStart
        #expect(resumedSegment != nil)
        await service.pause()
        engine.state = .playing
        await service.handleAudioStateChanged(.playing)
        #expect(container.playerState.playbackState == .paused)
        await service.stop()
    }
    @Test func resumeThatHasToReopenTheStreamStaysLoading() async throws {
        let engine = FakePlaybackEngine()
        let container = try AppContainer(inMemory: true, engine: engine)
        let service = try #require(container.playerService as? PlayerService)
        container.playerState.currentTrack = DisplayableSong(
            from: Song(id: "reopen", title: "Reopen", duration: 180)
        )
        container.playerState.playbackState = .loading
        await service.setTestCurrentSource(.cached(URL(fileURLWithPath: "/dev/null")))
        // This test observes the command before an engine confirmation. Do not let the
        // native decoder's asynchronous rejection of the synthetic source race that assertion.
        // Real decoded playback and failures are covered by the recovery/engine suites.
        service.systemEngine.eventHandler = nil

        await service.resume()
        let published = container.playerState.playbackState
        // Leave no timers ticking: other suites share this process, and a stray 500 ms ticker
        // (plus its SwiftData saves) competes for the main actor with their own deadlines.
        await service.stopProgressTimer()
        await service.stopPositionSaveTimer()

        // The engine still has to confirm audio; the UI keeps the play request visibly active.
        #if os(macOS)
        #expect(service.systemEngine.hasCurrentItem)
        #else
        #expect(engine.calls.contains { if case .play = $0 { return true }; return false })
        #endif
        #expect(published == .loading)
        await service.stop()
    }

    @Test func resumeOfAnEngineHoldingTheTrackPublishesPlaying() async throws {
        let engine = FakePlaybackEngine()
        // The engine still holds the paused track: resuming it produces audio immediately.
        engine.state = .playing
        let container = try AppContainer(inMemory: true, engine: engine)
        let service = try #require(container.playerService as? PlayerService)
        container.playerState.currentTrack = DisplayableSong(
            from: Song(id: "holding", title: "Holding", duration: 180)
        )
        container.playerState.playbackState = .paused
        await service.setTestCurrentSource(.cached(URL(fileURLWithPath: "/dev/null")))

        await service.resume()
        let published = container.playerState.playbackState
        await service.stopProgressTimer()
        await service.stopPositionSaveTimer()

        #expect(engine.calls.contains(.resume))
        #expect(published == .playing)
    }
}

private extension PlayerService {
    func startSegmentForTest() { currentPlaySegmentStart = Date().addingTimeInterval(-10) }
    /// Test seam: `resume()` chooses between reopening the stream and resuming the engine from
    /// `currentSource`, which normal playback only ever sets during resolve.
    func setTestCurrentSource(_ source: MediaSource) { currentSource = source }
}
