import Foundation
import Testing
import SwiftSonic
@testable import Cassette

struct PlaybackDurationPolicyTests {
    @Test func transcodingLengthCannotInflateFourMinuteSongTo101Minutes() {
        #expect(PlaybackDurationPolicy.resolve(catalog: 247, engine: 6061, engineIsEstimate: true) == 247)
    }
    @Test func incompleteEstimateCannotShortenSong() {
        #expect(PlaybackDurationPolicy.resolve(catalog: 247, engine: 37, engineIsEstimate: true) == 247)
    }
    @Test func smallParserCorrectionIsPreserved() {
        #expect(PlaybackDurationPolicy.resolve(catalog: 247, engine: 247.8, engineIsEstimate: true) == 247.8)
    }
    @Test func nativeTimelineCanCorrectStaleCatalogMetadata() {
        #expect(PlaybackDurationPolicy.resolve(catalog: 247, engine: 300, engineIsEstimate: false) == 300)
    }
    @Test(arguments: [Double.nan, .infinity, -.infinity, -1, 0])
    func unusableEngineDurationFallsBackToCatalog(_ invalid: Double) {
        #expect(PlaybackDurationPolicy.resolve(catalog: 247, engine: invalid, engineIsEstimate: true) == 247)
    }
    @Test func unknownCatalogUsesEngineWithoutAnArbitraryMusicLengthLimit() {
        #expect(PlaybackDurationPolicy.resolve(catalog: 0, engine: 7200, engineIsEstimate: true) == 7200)
        #expect(PlaybackDurationPolicy.resolve(catalog: .nan, engine: 250, engineIsEstimate: true) == 250)
        #expect(PlaybackDurationPolicy.resolve(catalog: .infinity, engine: .nan, engineIsEstimate: false) == 0)
    }
}

@MainActor
struct PlaybackClockRegressionTests {
    @Test func realProgressTimerRejectsInflatedDuration() async throws {
        let engine = FakePlaybackEngine()
        engine.progress = 37
        engine.duration = 6061
        engine.isSeekable = true
        let container = try AppContainer(inMemory: true, engine: engine)
        let service = try #require(container.playerService as? PlayerService)
        container.playerState.currentTrack = DisplayableSong(from: Song(id: "duration-regression", title: "Bad", duration: 247))
        container.playerState.duration = 6061
        await service.startProgressTimer()
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while container.playerState.position != 37, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        await service.stopProgressTimer()
        #expect(container.playerState.duration == 247)
        #expect(container.playerState.position == 37)
    }

    @Test func handoverNeverPublishesOutgoingClock() async throws {
        let engine = FakePlaybackEngine()
        engine.progress = 37
        engine.duration = 6061
        let container = try AppContainer(inMemory: true, engine: engine)
        let service = try #require(container.playerService as? PlayerService)
        container.playerState.currentTrack = DisplayableSong(from: Song(id: "incoming", title: "Incoming", duration: 247))
        container.playerState.duration = 247
        await service.setClockTestTransitionPending()
        await service.startProgressTimer()
        try await Task.sleep(for: .milliseconds(1200))
        await service.stopProgressTimer()
        #expect(container.playerState.duration == 247)
        #expect(container.playerState.position == 0)
    }
}

private extension PlayerService {
    func setClockTestTransitionPending() { isTrackTransitionPending = true }
}
