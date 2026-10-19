import Testing
import Foundation
import AVFoundation
@testable import Cassette

@Suite("Native decoded-audio meter", .serialized) @MainActor
struct NativePlaybackMeterTests {
    @Test("AVPlayer PCM drives the meter, silence decays, and seek retains transport")
    func nativePCM() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("meter-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1))
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 176400))
            pcm.frameLength = 176400
            let samples = try #require(pcm.floatChannelData)[0]
            for frame in 0..<176400 {
                samples[frame] = frame < 88200 ? 0.24 * sin(Float(frame) * 2 * .pi * 440 / 44100) : 0
            }
            try file.write(from: pcm)
        }
        // This verifies PCM delivery, independently of the host's thermal/foreground budget.
        let previousBudget = CassettePerformance.budget
        CassettePerformance.publish(.placeholder)
        defer { CassettePerformance.publish(previousBudget); PlaybackBeatMeter.shared.refreshPerformanceBudget() }
        let meter = PlaybackBeatMeter.shared
        let engine = AVPlayerPlaybackEngine()
        meter.setEnabled(true)
        meter.retainUIListening()
        defer { engine.stop(); meter.releaseUIListening(); meter.setEnabled(false) }
        engine.start(url: url, headers: [:], generation: 1, allowsAudioAnalysis: true)
        let id = try #require(engine.playerIdentity)
        let deadline = Date().addingTimeInterval(6)
        while meter.level < 0.1, Date() < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(meter.level > 0.1)
        let peak = meter.level
        engine.seek(to: 2.4)
        let quietDeadline = Date().addingTimeInterval(3)
        while (engine.isSeeking || meter.level > peak * 0.25), Date() < quietDeadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(meter.level < peak * 0.25)
        #expect(engine.playerIdentity == id)
        #expect(!engine.lastSeekFailed)
        engine.pause()
        #expect(engine.timeControlStatus == .paused)
    }
}
