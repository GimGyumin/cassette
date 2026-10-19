import AVFoundation
import AudioStreaming
import Foundation
import Testing
@testable import Cassette

@MainActor
@Suite("Playback recovery retains position", .serialized)
struct PlaybackRecoveryPositionTests {
    @Test("Explicit play works without an interruption-ended event", arguments: [false, true])
    func explicitPlaybackClearsUnendedInterruption(selectAnother: Bool) async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let f = try AuditPlaybackFixture()
        f.resolver.operation = { .downloaded(url) }
        f.container.playerState.position = 12
        f.engine.progress = 12
        _ = await f.player.beginSystemInterruption()
        f.container.playerState.playbackState = .paused
        f.engine.state = .paused
        // Automatic advancement must not clear the interruption or start a new song.
        try await f.player.play(tracks: [f.track], startIndex: 0, preservePlayingState: true)
        #expect(f.resolver.resolveCount == 0)
        #expect(await f.player.transport.interrupted)
        if selectAnother {
            let next = DisplayableSong(id: "after-interruption", title: "Next", duration: 30)
            try await f.player.play(tracks: [next], startIndex: 0)
            #expect(f.container.playerState.currentTrack?.id == next.id)
        } else {
            await f.player.resume()
            #expect(f.container.playerState.currentTrack?.id == f.track.id)
        }
        #expect(!(await f.player.transport.interrupted))
        let minimumPosition = selectAnother ? 0.1 : 12.1
        let deadline = Date().addingTimeInterval(5)
        while f.player.systemEngine.progress < minimumPosition, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(f.player.systemEngine.progress >= minimumPosition)
        await f.player.stop()
    }

    @Test func terminalFailureClearsStaleSeekAndCanReplayWithoutRelaunch() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let f = try AuditPlaybackFixture()
        f.resolver.operation = { .downloaded(url) }
        f.container.playerState.position = 12
        await f.player.armFailedSeekForRetry()
        let context = await f.player.playbackContext
        await f.player.finishPlaybackFailure(.timeout, context: context, position: 12)
        #expect(await f.player.seekState == .idle)
        #expect(!(await f.player.seekNeedsCommit))
        #expect(f.container.playerState.playbackState == .error(.timeout))
        await f.player.resume()
        #expect(f.resolver.resolveCount == 1)
        let deadline = Date().addingTimeInterval(5)
        while f.player.systemEngine.progress < 12.1, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(f.player.systemEngine.progress >= 12.1)
        #expect(f.container.playerState.currentTrack?.id == f.track.id)
        await f.player.stop()
    }

    private func fixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("recovery-\(UUID()).wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 240_000))
        buffer.frameLength = 240_000
        if let channel = buffer.floatChannelData?[0] {
            channel.update(repeating: 0, count: Int(buffer.frameLength))
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

    @Test("An unexpected mid-song reset restores position even with repeat-one enabled", arguments: [false, true])
    func midSongReset(viaProgressTimer: Bool) async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let container = try AppContainer(inMemory: true, engine: FakePlaybackEngine())
        let service = try #require(container.playerService as? PlayerService)
        let track = DisplayableSong(id: "reset", title: "Reset", duration: 30)
        container.playerState.currentTrack = track
        container.playerState.queue = [track]
        container.playerState.duration = 30
        container.playerState.position = 12
        container.playerState.playbackState = .playing
        container.playerState.repeatMode = .one
        await service.installRecoveryFixture(url: url, position: 12)
        if viaProgressTimer {
            await service.startProgressTimer()
            let opened = Date().addingTimeInterval(3)
            while !service.systemEngine.hasCurrentItem, Date() < opened {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(service.systemEngine.hasCurrentItem)
        } else {
            #expect(await service.recoverUnexpectedProgressReset(progress: 0))
        }
        #expect(container.playerState.currentTrack?.id == "reset")
        #expect(container.playerState.position >= 11.8)
        let deadline = Date().addingTimeInterval(5)
        while service.systemEngine.progress < 11.8, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(service.systemEngine.progress >= 11.8)
        await service.stop()
    }

    @Test("A second clock reset stops instead of creating a battery-draining restart loop")
    func repeatedResetFailsAtCheckpoint() async throws {
        let container = try AppContainer(inMemory: true, engine: FakePlaybackEngine())
        let service = try #require(container.playerService as? PlayerService)
        container.playerState.currentTrack = DisplayableSong(id: "reset", title: "Reset", duration: 180)
        container.playerState.duration = 180
        container.playerState.position = 40
        container.playerState.playbackState = .playing
        await service.installRecoveryFixture(url: URL(fileURLWithPath: "/tmp/unused.wav"), position: 40, alreadyRecovered: true)
        #expect(await service.recoverUnexpectedProgressReset(progress: 0))
        #expect(container.playerState.playbackState == .error(.timeout))
        #expect(await service.pendingRestoreInfo?.seekTime == 40)
        #expect(!service.systemEngine.hasCurrentItem)
        await service.stop()
    }

    @Test func pausedEmptyEngineOpensRestoredSourceInsteadOfResumingNothing() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = FakePlaybackEngine()
        engine.state = .paused
        let container = try AppContainer(inMemory: true, engine: engine)
        let service = try #require(container.playerService as? PlayerService)
        let track = DisplayableSong(id: "restored", title: "Restored", duration: 30)
        container.playerState.currentTrack = track
        container.playerState.queue = [track]
        container.playerState.position = 12
        container.playerState.duration = 30
        container.playerState.playbackState = .paused
        await service.installRecoveryFixture(url: url, position: 12)
        await service.installPausedRestorationCheckpoint()
        await service.resume()
        #expect(!engine.calls.contains(.resume))
        let deadline = Date().addingTimeInterval(5)
        while service.systemEngine.progress < 11.8, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(service.systemEngine.progress >= 11.8)
        #expect(container.playerState.playbackState != .paused)
        await service.stop()
    }

    @Test func emptyStreamDoesNotSkipSelectedTrack() async throws {
        let container = try AppContainer(inMemory: true, engine: FakePlaybackEngine())
        let service = try #require(container.playerService as? PlayerService)
        let track = DisplayableSong(id: "empty", title: "Empty", duration: 180)
        container.playerState.currentTrack = track
        container.playerState.queue = [track, DisplayableSong(id: "next", title: "Next", duration: 180)]
        container.playerState.duration = 180
        container.playerState.playbackState = .loading
        await service.installRecoveryFixture(url: URL(fileURLWithPath: "/tmp/empty.wav"), position: 0)
        await service.handleEndOfTrack(engineConfirmed: true, finishedProgress: 0)
        #expect(container.playerState.currentTrack?.id == "empty")
        #expect(container.playerState.currentIndex == 0)
        #expect(container.playerState.playbackState == .error(.timeout))
        await service.stop()
    }

    @Test func delayedEOFCannotEndANewerSelectionOfTheSameURL() async throws {
        let container = try AppContainer(inMemory: true, engine: FakePlaybackEngine())
        let service = try #require(container.playerService as? PlayerService)
        let track = DisplayableSong(id: "same", title: "Same", duration: 180)
        container.playerState.currentTrack = track
        container.playerState.queue = [track]
        container.playerState.duration = 180
        container.playerState.playbackState = .playing
        let url = URL(fileURLWithPath: "/tmp/same.wav")
        await service.installRecoveryFixture(url: url, position: 0)
        let old = await service.playbackContext
        await service.advanceCommandForEOFTest()
        await service.handleEndOfTrack(engineConfirmed: true, finishedEntryIdentifier: url.absoluteString,
                                       expectedContext: old, finishedProgress: 180)
        #expect(container.playerState.playbackState == .playing)
        #expect(container.playerState.currentTrack?.id == "same")
        #expect(await service.lastEndOfTrackTransitionAt == .distantPast)
        await service.stop()
    }

    @Test func endAndExplicitSeekAreNotMidSongResets() async throws {
        let container = try AppContainer(inMemory: true, engine: FakePlaybackEngine())
        let service = try #require(container.playerService as? PlayerService)
        container.playerState.currentTrack = DisplayableSong(id: "end", title: "End", duration: 30)
        container.playerState.duration = 30
        container.playerState.playbackState = .playing
        await service.installRecoveryFixture(url: URL(fileURLWithPath: "/tmp/unused.wav"), position: 29.8)
        #expect(!(await service.recoverUnexpectedProgressReset(progress: 0)))
        await service.seek(to: 0)
        #expect(!(await service.recoverUnexpectedProgressReset(progress: 0)))
        await service.stop()
    }

    @Test func pauseDuringRecoveryKeepsItsSourceAndSeek() async throws {
        let container = try AppContainer(inMemory: true, engine: FakePlaybackEngine())
        let service = try #require(container.playerService as? PlayerService)
        container.playerState.currentTrack = DisplayableSong(id: "recovering", title: "Recovering", duration: 180)
        container.playerState.duration = 180
        container.playerState.position = 40
        container.playerState.playbackState = .recovering
        await service.installRecoveryFixture(url: URL(fileURLWithPath: "/tmp/retained.wav"), position: 40)
        await service.armRecoveryTransitionForPause()
        await service.pause()
        #expect(await service.currentSource != nil)
        #expect(await service.pendingRestoreInfo?.seekTime == 40)
        #expect(await service.pendingRestoreInfo?.pause == true)
        #expect(container.playerState.playbackState == .paused)
        await service.stop()
    }
}

private extension PlayerService {
    func armFailedSeekForRetry() {
        seekState = .settling(target: 120, deadline: Date().addingTimeInterval(12))
        seekNeedsCommit = true
    }
    func installPausedRestorationCheckpoint() { pendingRestoreInfo = (seekTime: 12, pause: true) }
    func advanceCommandForEOFTest() { transportCommandID &+= 1 }
    func armRecoveryTransitionForPause() {
        isTrackTransitionPending = true
        pendingRestoreInfo = (seekTime: 40, pause: false)
    }
    func installRecoveryFixture(url: URL, position: Double, alreadyRecovered: Bool = false) {
        currentSource = .downloaded(url)
        lastObservedEngineProgress = position
        systemPlayback.recoveredCurrentStall = alreadyRecovered
    }
}
