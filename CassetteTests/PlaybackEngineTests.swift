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
    func seek(to time: Double) { record(.seek(time)) }
}

/// Real `PlayerService`, real wiring, fake engine. Deliberately narrow: it proves the seam works
/// end to end (the composition root hands the engine to the actor and the actor reaches it), which
/// is the precondition for the wider queue/transition tests.
@MainActor
@Suite("PlayerService × PlaybackEngine")
struct PlayerServiceEngineTests {

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

@MainActor
@Suite("Native playback engine lifetime")
struct AVPlayerEngineTests {
    @Test func cancellingNextTrackAndStoppingReleaseTheNativeQueue() throws {
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
        #expect(engine.prepareNext(url: next, headers: [:]))
        #expect(!engine.consumeQueuedTransition())
        engine.removeFromQueue(url: first)
        #expect(engine.hasQueuedItem)
        engine.removeFromQueue(url: next)
        #expect(!engine.hasQueuedItem)
        #expect(engine.hasCurrentItem)
        #expect(engine.prepareNext(url: next, headers: [:]))
        engine.stop()
        #expect(!engine.hasCurrentItem && !engine.hasQueuedItem)
        #expect(engine.observedItemID == nil)
        #expect(!engine.consumeQueuedTransition())
        #expect(!engine.prepareNext(url: next, headers: [:]))
        #expect(engine.state == .stopped)
    }
}
