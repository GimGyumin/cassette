import Testing
import Foundation
import AVFoundation
import AudioStreaming
@testable import Cassette

@Suite("Prepared gapless transport", .serialized) @MainActor
struct GaplessContinuityTests {
    @Test func idleFallbackDoesNotCreateAnAudioGraph() {
        let engine = AudioStreamingPlayerEngine()
        let eq = AVAudioUnitEQ()
        eq.globalGain = -6
        engine.attach(node: eq)
        engine.volume = 0.25
        engine.addFrameFilter(named: "unused") { _, _ in }
        engine.removeFrameFilter(named: "unused")
        for _ in 0..<1000 {
            #expect(engine.progress == 0)
            #expect(engine.duration == 0)
            #expect(!engine.isSeekable)
        }
        engine.pause()
        engine.resume()
        engine.seek(to: 1)
        engine.stop()
        #expect(engine.state == .stopped)
        #expect(engine.volume == 0.25)
        #expect(engine.playerIdentity == nil)
        #expect(eq.engine == nil)
        engine.resetAfterMediaServicesReset()
        #expect(engine.playerIdentity == nil)
    }

    @Test func deferredGraphPreservesGainAndOnlyInstallsOnce() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = AudioStreamingPlayerEngine()
        let eq = AVAudioUnitEQ()
        eq.globalGain = -6
        engine.attach(node: eq)
        engine.attach(node: eq)
        engine.volume = 0
        #expect(engine.playerIdentity == nil)
        engine.play(url: url, headers: [:])
        defer { engine.stop() }
        let identity = try #require(engine.playerIdentity)
        #expect(eq.engine != nil)
        #expect(eq.globalGain == -6)
        #expect(engine.volume == 0)
        engine.queue(url: url, headers: [:])
        #expect(engine.playerIdentity == identity)
    }

    @Test func stoppedAndFailedStreamingEnginesCannotPoisonFollowingTracks() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = AudioStreamingPlayerEngine()
        engine.volume = 0
        defer { engine.stop() }
        let eq = AVAudioUnitEQ()
        eq.globalGain = -6
        engine.attach(node: eq)
        let invalid = url.deletingLastPathComponent().appendingPathComponent("missing-\(UUID()).mp3")
        engine.play(url: invalid, headers: [:])
        let deadline = Date().addingTimeInterval(3)
        while engine.state != .error, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(engine.state == .error)
        for _ in 0..<3 {
            let previous = engine.playerIdentity
            engine.stop()
            engine.play(url: url, headers: [:])
            #expect(engine.playerIdentity != previous)
            #expect(eq.globalGain == -6)
            let started = Date().addingTimeInterval(4)
            while engine.progress < 0.1, Date() < started { try await Task.sleep(for: .milliseconds(10)) }
            #expect(engine.progress >= 0.1)
            #expect(engine.state == .playing)
        }
    }
    private func fixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gapless-\(UUID()).wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2))
        let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 110250))
        pcm.frameLength = 110250 // Exactly 2.5 seconds, with no encoded padding.
        let channels = try #require(pcm.floatChannelData)
        for frame in 0..<Int(pcm.frameLength) {
            let sample = Float(0.2 * sin(Double(frame) * 2 * .pi * 440 / 44100))
            channels[0][frame] = sample
            channels[1][frame] = sample
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: pcm)
        return url
    }

    @Test("Prepared tracks advance without a half-second transport pause", arguments: [false, true])
    func continuousClock(native: Bool) async throws {
        let first = try fixture()
        let next = try fixture()
        defer { try? FileManager.default.removeItem(at: first); try? FileManager.default.removeItem(at: next) }
        let engine: any PlaybackEngine = native ? AVPlayerPlaybackEngine() : AudioStreamingPlayerEngine()
        engine.volume = 0
        defer { engine.stop() }
        engine.play(url: first, headers: [:])
        let startupDeadline = Date().addingTimeInterval(5)
        while engine.progress < 0.2, Date() < startupDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(engine.state == .playing && engine.progress < 1.5)
        if let nativeEngine = engine as? AVPlayerPlaybackEngine {
            #expect(nativeEngine.prepareNext(url: next, headers: [:]))
        } else {
            engine.queue(url: next, headers: [:])
        }
        // Exclude cold decoder/device startup and measure only the track boundary.
        while engine.progress < 1.2, Date() < startupDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(engine.progress >= 1.2 && engine.progress < 2)
        let initialPosition = engine.progress
        let start = ProcessInfo.processInfo.systemUptime
        var previous = initialPosition
        var advanced = false
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline {
            if let nativeEngine = engine as? AVPlayerPlaybackEngine {
                advanced = nativeEngine.consumeQueuedTransition() || advanced
            }
            let position = engine.progress
            if !native, previous > 1.5, position < 1 { advanced = true }
            if advanced, position >= 0.4 {
                let elapsed = ProcessInfo.processInfo.systemUptime - start
                let missingTime = elapsed - (2.5 - initialPosition + position)
                print("Gapless clock loss (native=\(native)): \(missingTime) seconds")
                // Allow render-quantum jitter, but reject tap-induced 200–500 ms gaps.
                #expect(missingTime < 0.08, "Transition lost \(missingTime) seconds (native=\(native))")
                #expect(engine.state == .playing)
                return
            }
            previous = position
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("The prepared next track never advanced (native=\(native))")
    }
}
