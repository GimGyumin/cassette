import Testing
import Foundation
import AVFoundation
import AudioStreaming
@testable import Cassette

@Suite("Cached/downloaded seek clocks", .serialized)
@MainActor
struct LocalSeekSmoothnessTests {
    private func service(engine: FakePlaybackEngine, cached: Bool) async throws -> (AppContainer, PlayerService) {
        let container = try AppContainer(inMemory: true, engine: engine)
        let service = try #require(container.playerService as? PlayerService)
        container.playerState.currentTrack = DisplayableSong(id: "local", title: "Local", duration: 180)
        container.playerState.duration = 180
        container.playerState.position = engine.progress
        container.playerState.playbackState = .playing
        await service.installLocalSeekFixture(URL(fileURLWithPath: "/tmp/local-seek-fixture.m4a"), cached: cached)
        return (container, service)
    }

    @Test("A small backwards seek cannot settle against the old file clock", arguments: [false, true])
    func smallBackwardSeek(cached: Bool) async throws {
        let engine = FakePlaybackEngine()
        engine.state = .playing
        engine.isSeekable = true
        engine.duration = 180
        engine.progress = 10
        let (container, service) = try await service(engine: engine, cached: cached)
        await service.seek(to: 9)
        #expect(await service.reconcilePendingSeek(engineProgress: 10).isSettling)
        #expect(container.playerState.pendingSeekPosition == 9)
        #expect(container.playerState.position == 9)
        // An old .playing callback must not unfreeze the lyric clock.
        await service.publishEnginePlaybackConfirmation()
        #expect(container.playerState.playbackState == .recovering)
        engine.progress = 9
        let deadline = Date().addingTimeInterval(2)
        while container.playerState.pendingSeekPosition != nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(container.playerState.pendingSeekPosition == nil)
        #expect(container.playerState.playbackState == .playing)
        #expect(engine.calls.contains(.seek(9)))
        await service.stop()
    }

    @Test("Fast local releases coalesce to the final target without reopening the file", arguments: [false, true])
    func rapidReleases(cached: Bool) async throws {
        let engine = FakePlaybackEngine()
        engine.state = .playing
        engine.isSeekable = true
        engine.duration = 180
        let (container, service) = try await service(engine: engine, cached: cached)
        let first = Task { await service.seek(to: 60) }
        try await Task.sleep(for: .milliseconds(15))
        let second = Task { await service.seek(to: 90) }
        try await Task.sleep(for: .milliseconds(15))
        await service.seek(to: 30)
        await first.value
        await second.value
        let requests = engine.calls.compactMap { call -> Double? in
            if case .seek(let target) = call { return target }; return nil
        }
        #expect(requests == [30])
        #expect(container.playerState.pendingSeekPosition == 30)
        #expect(!service.systemEngine.hasCurrentItem)
        engine.progress = 30
        let deadline = Date().addingTimeInterval(2)
        while container.playerState.pendingSeekPosition != nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(container.playerState.position >= 30)
        await service.stop()
        #expect(container.playerState.pendingSeekPosition == nil)
    }

    @Test("Pause during a coalesced local seek keeps the original engine and final target")
    func pauseDuringPendingLocalSeek() async throws {
        let engine = FakePlaybackEngine()
        engine.state = .playing
        engine.isSeekable = true
        engine.duration = 180
        let (container, service) = try await service(engine: engine, cached: true)
        let pending = Task { await service.seek(to: 60) }
        let deadline = Date().addingTimeInterval(2)
        while container.playerState.pendingSeekPosition == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        await service.pause()
        await pending.value
        #expect(container.playerState.playbackState == .paused)
        #expect(!service.systemEngine.hasCurrentItem)
        #expect(engine.calls.contains(.seek(60)))
        engine.progress = 60
        engine.state = .paused
        let settle = Date().addingTimeInterval(2)
        while container.playerState.pendingSeekPosition != nil, Date() < settle {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(container.playerState.pendingSeekPosition == nil)
        #expect(container.playerState.playbackState == .paused)
        await service.stop()
    }

    @Test("Real local AAC seeks retain AVPlayer and playback intent", arguments: [false, true], [false, true])
    func realLocalAAC(cached: Bool, paused: Bool) async throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/SilentAAC.adts")
        let local = FileManager.default.temporaryDirectory.appendingPathComponent("local-aac-\(UUID().uuidString).aac")
        try FileManager.default.copyItem(at: fixture, to: local)
        defer { try? FileManager.default.removeItem(at: local) }
        let container = try AppContainer(inMemory: true, engine: FakePlaybackEngine())
        let service = try #require(container.playerService as? PlayerService)
        container.playerState.currentTrack = DisplayableSong(id: "local-aac", title: "Local AAC", duration: 5)
        container.playerState.duration = 5
        container.playerState.playbackState = paused ? .paused : .playing
        await service.startLocalAACFixture(local, cached: cached, paused: paused)
        let ready = Date().addingTimeInterval(5)
        while !service.systemEngine.isReadyForPlayback, Date() < ready {
            try await Task.sleep(for: .milliseconds(20))
        }
        let playerID = try #require(service.systemEngine.playerIdentity)
        let first = Task { await service.seek(to: 2) }
        try await Task.sleep(for: .milliseconds(15))
        let second = Task { await service.seek(to: 0.5) }
        try await Task.sleep(for: .milliseconds(15))
        await service.seek(to: 3)
        await first.value
        await second.value
        let settle = Date().addingTimeInterval(5)
        while container.playerState.pendingSeekPosition != nil, Date() < settle {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(container.playerState.pendingSeekPosition == nil)
        #expect(service.systemEngine.playerIdentity == playerID)
        #expect(abs(service.systemEngine.progress - 3) < 0.3)
        // A landed seek and audible output are separate native callbacks. Keep the
        // assertion on confirmed playback, allowing the audio device to start after seeking.
        let expectedState: PlaybackState = paused ? .paused : .playing
        let audible = Date().addingTimeInterval(2)
        while container.playerState.playbackState != expectedState, Date() < audible {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(container.playerState.playbackState == (paused ? .paused : .playing))
        let systemControls = NowPlayingService(playerService: service, artworkImageCache: container.artworkImageCache)
        await systemControls.seekFromSystem(to: 0)
        let beginning = Date().addingTimeInterval(5)
        while container.playerState.pendingSeekPosition != nil, Date() < beginning {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(container.playerState.pendingSeekPosition == nil)
        #expect(service.systemEngine.progress < 0.5)
        #expect(service.systemEngine.playerIdentity == playerID)
        await systemControls.stop()
        await service.stop()
    }
}

private extension PlayerService {
    func installLocalSeekFixture(_ url: URL, cached: Bool) { currentSource = cached ? .cached(url) : .downloaded(url) }
    func startLocalAACFixture(_ url: URL, cached: Bool, paused: Bool) {
        installLocalSeekFixture(url, cached: cached)
        pendingRestoreInfo = (seekTime: 0, pause: paused)
        startEnginePlayback(url: url, headers: [:], useSystemPlayer: true)
    }
}
