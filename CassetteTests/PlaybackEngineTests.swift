// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Testing
import Foundation
import AudioStreaming
@testable import Cassette

/// Test double for the audio engine.
///
/// `PlayerService` is the single owner of playback state, but the engine under it is where audio
/// actually happens. Recording what the app asked the engine to do (and letting a test drive the
/// delegate) is what makes queue/transition logic testable without audio hardware — and it is the
/// seam the `PlayerService` decomposition is built on.
nonisolated final class FakePlaybackEngine: AudioStreamingPlaybackEngine, @unchecked Sendable {

    enum Call: Equatable {
        case play(URL, [String: String])
        case queue(URL, [String: String])
        case removeFromQueue(URL)
        case stop
        case pause
        case resume
        case recoverQueuedTransition
        case seek(Double)
    }

    private let lock = NSLock()
    private var recorded: [Call] = []

    /// Everything the app asked for, in order.
    var calls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func reset() {
        lock.lock()
        recorded.removeAll()
        lock.unlock()
    }

    private func record(_ call: Call) {
        lock.lock()
        recorded.append(call)
        lock.unlock()
    }

    // Mutable so a test can simulate engine state (buffering, EOF, a failing seek).
    var state: AudioPlayerState = .ready
    var progress: Double = 0
    var duration: Double = 0
    var isSeekable = false
    var volume: Float = 1
    var delegate: AudioPlayerDelegate?

    func play(url: URL, headers: [String: String]) { record(.play(url, headers)) }
    func queue(url: URL, headers: [String: String]) { record(.queue(url, headers)) }
    func removeFromQueue(url: URL) { record(.removeFromQueue(url)) }
    func stop() { record(.stop) }
    func pause() { record(.pause) }
    func resume() { record(.resume) }
    func recoverQueuedTransitionIfNeeded() { record(.recoverQueuedTransition) }
    func seek(to time: Double) { record(.seek(time)) }
}

/// Real `PlayerService`, real wiring, fake engine. Deliberately narrow: it proves the seam works
/// end to end (the composition root hands the engine to the actor and the actor reaches it), which
/// is the precondition for the wider queue/transition tests.
@MainActor
@Suite("PlayerService × PlaybackEngine")
struct PlayerServiceEngineTests {
    @Test func earlySeekCannotTurnAnEOFCallbackIntoNextTrack() async throws {
        let engine = FakePlaybackEngine()
        engine.isSeekable = true
        let container = try AppContainer(inMemory: true, engine: engine)
        let service = try #require(container.playerService as? PlayerService)
        let first = DisplayableSong(id: "first", title: "First", duration: 180)
        let second = DisplayableSong(id: "second", title: "Second", duration: 180)
        container.playerState.queue = [first, second]
        container.playerState.currentIndex = 0
        container.playerState.currentTrack = first
        container.playerState.duration = 180
        container.playerState.playbackState = .loading
        await service.seek(to: 60)
        await service.handleEndOfTrack(engineConfirmed: true)
        #expect(container.playerState.currentIndex == 0)
        #expect(container.playerState.currentTrack?.id == "first")
        #expect(container.playerState.position == 60)
        #expect(engine.calls.contains(.seek(60)))
        await service.stop()
    }

    @Test func deferredHistoryKeepsTheOutgoingTracksDuration() async throws {
        let container = try AppContainer(inMemory: true, engine: FakePlaybackEngine())
        let service = try #require(container.playerService as? PlayerService)
        let server = ServerSnapshot(from: ServerConfig(displayName: "History test", baseURL: "https://example.invalid", username: "test"))
        container.serverState.activeServer = server
        // The UI already displays the incoming song by the time the outgoing event is saved.
        container.playerState.currentTrack = DisplayableSong(id: "incoming", title: "Incoming", duration: 600)
        container.playerState.duration = 600
        let outgoing = DisplayableSong(id: "outgoing", title: "Outgoing", duration: 180)
        await service.recordOutgoingHistoryForTest(outgoing)
        let events = await container.statsService.recentEvents(limit: 10, serverId: server.id.uuidString)
        #expect(events.count == 1)
        #expect(events.first?.trackId == "outgoing")
        #expect(events.first?.trackDuration == 180)
        #expect(events.first?.durationListened == 45)
        #expect(events.first?.wasCompleted == false)
    }

    @Test func gaplessSelectionMustWaitForActualClockProgress() {
        #expect(!PlayerService.confirmsBridgedEntryProgress(
            previous: 0,
            current: 0,
            engineState: .paused
        ))
        #expect(!PlayerService.confirmsBridgedEntryProgress(
            previous: 0,
            current: 0,
            engineState: .playing
        ))
        #expect(PlayerService.confirmsBridgedEntryProgress(
            previous: 0,
            current: 0.12,
            engineState: .playing
        ))
        #expect(PlayerService.confirmsBridgedEntryProgress(
            previous: 217,
            current: 0.1,
            engineState: .playing
        ))
    }

    @Test func gaplessRecoveryLeavesNormalHandoffsUninterrupted() {
        #expect(!PlayerService.shouldRecoverBridgedEntry(
            selected: true, elapsed: 0.12, previous: 0, current: 0, engineState: .bufferring
        ))
        #expect(!PlayerService.shouldRecoverBridgedEntry(
            selected: true, elapsed: 0.8, previous: 0.1, current: 0.22, engineState: .playing
        ))
        #expect(!PlayerService.shouldRecoverBridgedEntry(
            selected: false, elapsed: 1, previous: 200, current: 200, engineState: .bufferring
        ))
        #expect(PlayerService.shouldRecoverBridgedEntry(
            selected: true, elapsed: 0.8, previous: 0, current: 0, engineState: .bufferring
        ))
        #expect(PlayerService.shouldRecoverBridgedEntry(
            selected: true, elapsed: 0.8, previous: 0, current: 0, engineState: .paused
        ))
    }

    @Test func acquisitionRecoveryOnlyTargetsTheCurrentRemoteTrackWithoutProgress() {
        for phase in [PlaybackState.buffering, .recovering] {
            #expect(!PlayerService.shouldRecoverAcquiringPlayback(
                trackMatches: true, playbackState: phase, engineProgress: 0,
                sourceIsLocal: false, transitionPending: false
            ))
        }
        for progress in [0.25, 2.0, 90.0, Double.nan, Double.infinity] {
            #expect(!PlayerService.shouldRecoverAcquiringPlayback(
                trackMatches: true,
                playbackState: .loading,
                engineProgress: progress,
                sourceIsLocal: false,
                transitionPending: false
            ))
        }
        #expect(PlayerService.shouldRecoverAcquiringPlayback(
            trackMatches: true,
            playbackState: .loading,
            engineProgress: 0,
            sourceIsLocal: false,
            transitionPending: false
        ))
        #expect(PlayerService.shouldRecoverAcquiringPlayback(
            trackMatches: true,
            playbackState: .playing,
            engineProgress: 0,
            sourceIsLocal: false,
            transitionPending: false
        ))
        #expect(!PlayerService.shouldRecoverAcquiringPlayback(
            trackMatches: true,
            playbackState: .playing,
            engineProgress: 2,
            sourceIsLocal: false,
            transitionPending: false
        ))
        #expect(!PlayerService.shouldRecoverAcquiringPlayback(
            trackMatches: true,
            playbackState: .loading,
            engineProgress: 0,
            sourceIsLocal: true,
            transitionPending: false
        ))
        #expect(!PlayerService.shouldRecoverAcquiringPlayback(
            trackMatches: false,
            playbackState: .loading,
            engineProgress: 0,
            sourceIsLocal: false,
            transitionPending: false
        ))
        #expect(!PlayerService.shouldRecoverAcquiringPlayback(
            trackMatches: true,
            playbackState: .loading,
            engineProgress: 0,
            sourceIsLocal: false,
            transitionPending: true
        ))
    }

    @Test func engineReceivesTheDelegate() throws {
        let engine = FakePlaybackEngine()
        let container = try AppContainer(inMemory: true, engine: engine)
        // PlayerService owns the engine for the app lifetime and must attach its callback bridge,
        // otherwise no state change, EOF or error would ever reach it.
        #expect(engine.delegate != nil)
        _ = container
    }

    @Test func stopAudioEngineSyncReachesTheEngine() throws {
        let engine = FakePlaybackEngine()
        let container = try AppContainer(inMemory: true, engine: engine)
        container.playerService.stopAudioEngineSync()
        #expect(engine.calls.contains(.stop))
    }

    #if os(macOS)
    @Test func setVolumeReachesTheEngine() async throws {
        // iOS routes volume through SystemVolumeView; macOS uses the software path, which is the
        // engine's volume. This is the shortest real end-to-end path: protocol → actor → engine.
        let engine = FakePlaybackEngine()
        let container = try AppContainer(inMemory: true, engine: engine)
        await container.playerService.setVolume(0.42)
        #expect(engine.volume == 0.42)
    }
    #endif

    @Test func unclampedVolumeIsBoundedBeforeReachingTheEngine() async throws {
        let engine = FakePlaybackEngine()
        let container = try AppContainer(inMemory: true, engine: engine)
        await container.playerService.setVolume(5)
        #expect(engine.volume <= 1)
        #expect(engine.volume >= 0)
    }
}

private extension PlayerService {
    func recordOutgoingHistoryForTest(_ song: DisplayableSong) async {
        trackPlayStartDate = Date().addingTimeInterval(-45)
        accumulatedPlayedSeconds = 45
        currentPlaySegmentStart = nil
        wasTrackCompletedNaturally = false
        await recordCurrentTrackPlayback(trigger: "user_skipped", overridingTrack: song)
        // Mutating the live counters must not affect the queued immutable history event.
        accumulatedPlayedSeconds = 0
        wasTrackCompletedNaturally = true
        await historyWriteTask?.value
    }
}

@MainActor
@Suite("Native playback engine lifetime")
struct AVPlayerEngineTests {
    @Test func cancellingNextTrackAndStoppingReleaseTheNativeQueue() async throws {
        let engine = AVPlayerPlaybackEngine()
        let first = FileManager.default.temporaryDirectory.appendingPathComponent("first-\(UUID()).wav")
        let next = FileManager.default.temporaryDirectory.appendingPathComponent("next-\(UUID()).wav")
        var wave = Data("RIFF".utf8)
        func append32(_ value: UInt32) { var little = value.littleEndian; withUnsafeBytes(of: &little) { wave.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { var little = value.littleEndian; withUnsafeBytes(of: &little) { wave.append(contentsOf: $0) } }
        append32(16036); wave.append(Data("WAVEfmt ".utf8)); append32(16)
        append16(1); append16(1); append32(8000); append32(16000); append16(2); append16(16)
        wave.append(Data("data".utf8)); append32(16000); wave.append(Data(count: 16000))
        try wave.write(to: first); try wave.write(to: next)
        defer { try? FileManager.default.removeItem(at: first); try? FileManager.default.removeItem(at: next) }
        // Paused file items exercise queue ownership without networking or audio output.
        engine.start(url: first, headers: [:], generation: 1, paused: true)
        #expect(engine.hasCurrentItem)
        engine.seek(to: 0.2)
        engine.seek(to: 0.7)
        let deadline = Date().addingTimeInterval(3)
        while abs(engine.progress - 0.7) > 0.05, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(abs(engine.progress - 0.7) <= 0.05)
        #expect(engine.state == .paused)
        #expect(engine.prepareNext(url: next, headers: [:]))
        #expect(!engine.consumeQueuedTransition())
        engine.removeFromQueue(url: first)
        #expect(engine.hasQueuedItem)
        engine.removeFromQueue(url: next)
        #expect(!engine.hasQueuedItem)
        #expect(engine.hasCurrentItem)
        #expect(engine.prepareNext(url: next, headers: [:]))
        let previousItem = engine.observedItemID
        #expect(!engine.advanceToPreparedNext(expectedURL: first))
        #expect(engine.observedItemID == previousItem)
        #expect(engine.advanceToPreparedNext(expectedURL: next))
        engine.pause()
        #expect(engine.consumeQueuedTransition())
        #expect(engine.observedItemID != previousItem)
        #expect(!engine.hasQueuedItem)
        #expect(!engine.consumeQueuedTransition())
        #expect(!engine.advanceToPreparedNext(expectedURL: next))
        engine.seek(to: 0.4)
        engine.stop()
        try await Task.sleep(for: .milliseconds(50))
        #expect(!engine.hasCurrentItem && !engine.hasQueuedItem)
        #expect(engine.observedItemID == nil)
        #expect(!engine.consumeQueuedTransition())
        #expect(!engine.prepareNext(url: next, headers: [:]))
        #expect(engine.state == .stopped)
    }
}
