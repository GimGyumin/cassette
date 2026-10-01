import AudioStreaming
import Foundation
import SwiftSonic
import Testing
@testable import Cassette

/// The transport must never show a pause/stop control for a stream that has not produced audio.
///
/// Reported from a device: tapping a song flipped the play button to the pause glyph while the
/// stream was still loading. Two halves are covered here — the appearance rule the controls render
/// from, and the rule that ends a `.loading` start.
@Suite("Playback control appearance")
struct PlaybackControlAppearanceTests {

    // MARK: - What the control renders

    @Test func loadingNeverRendersAsPause() {
        // The transports draw this as the plain play glyph — no spinner, still inert — because no
        // audio exists yet. The point of the case is only that it is *not* the pause/stop control.
        #expect(PlaybackState.loading.controlAppearance == .loading)
    }

    @Test func onlyConfirmedPlaybackRendersAsPause() {
        #expect(PlaybackState.playing.controlAppearance == .pause)
    }

    @Test func idlePausedAndErrorRenderAsPlay() {
        #expect(PlaybackState.idle.controlAppearance == .play)
        #expect(PlaybackState.paused.controlAppearance == .play)
        #expect(PlaybackState.error(.timeout).controlAppearance == .play)
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
    @Test func resumeThatHasToReopenTheStreamStaysLoading() async throws {
        let engine = FakePlaybackEngine()
        let container = try AppContainer(inMemory: true, engine: engine)
        let service = try #require(container.playerService as? PlayerService)
        container.playerState.currentTrack = DisplayableSong(
            from: Song(id: "reopen", title: "Reopen", duration: 180)
        )
        container.playerState.playbackState = .loading
        await service.setTestCurrentSource(.cached(URL(fileURLWithPath: "/dev/null")))

        await service.resume()
        let published = container.playerState.playbackState
        // Leave no timers ticking: other suites share this process, and a stray 500 ms ticker
        // (plus its SwiftData saves) competes for the main actor with their own deadlines.
        await service.stopProgressTimer()
        await service.stopPositionSaveTimer()

        // The engine had to open the stream again, so no audio exists yet: the transport keeps its
        // loading appearance instead of switching to the pause/stop control.
        #expect(engine.calls.contains { if case .play = $0 { return true }; return false })
        #expect(published == .loading)
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
    /// Test seam: `resume()` chooses between reopening the stream and resuming the engine from
    /// `currentSource`, which normal playback only ever sets during resolve.
    func setTestCurrentSource(_ source: MediaSource) { currentSource = source }
}
