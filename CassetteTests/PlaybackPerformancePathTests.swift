import AVFoundation
import Foundation
import SwiftData
import Testing
@testable import Cassette

struct PlaybackPerformancePathTests {
    @Test func lyricSpacingPreservesMultilingualAndSecondaryText() {
        func words(_ values: [String], preserve: Bool = false) -> [LyricDisplayWord] {
            values.map { LyricDisplayWord(text: $0, startMs: 0, endMs: 100, role: .main, preservesSourceSpacing: preserve) }
        }
        #expect(LyricKaraokeSpacing.displayTexts(words(["Hello", "world"]), secondary: false) == ["Hello\u{00A0}", "world"])
        #expect(LyricKaraokeSpacing.displayTexts(words(["한", "글", "日", "本", "語"]), secondary: false).joined() == "한글日本語")
        #expect(LyricKaraokeSpacing.displayTexts(words(["one ", "two"]), secondary: false) == ["one\u{00A0}", "two"])
        #expect(LyricKaraokeSpacing.displayTexts(words(["can", "not"], preserve: true), secondary: false) == ["can", "not"])
        #expect(LyricKaraokeSpacing.displayTexts(words(["(oh)", "(yeah)"]), secondary: true) == ["oh\u{00A0}", "yeah"])
        #expect(LyricKaraokeSpacing.displayTexts([], secondary: false).isEmpty)
    }

    @Test func fixedStorageMeterMatchesExistingRMSCalculation() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2048))
        buffer.frameLength = 2048
        let samples = try #require(buffer.floatChannelData)
        for channel in 0..<2 {
            for frame in 0..<2048 { samples[channel][frame] = Float(frame % 31) / 100 * Float(channel + 1) }
        }
        let reference = PlaybackBeatMeter.bandEnergies(from: buffer)
        let fixed = PlaybackBeatMeter.fourBandEnergies(bufferList: buffer.audioBufferList,
            format: format.streamDescription.pointee, frameCount: Int(buffer.frameLength))
        for lane in 0..<4 { #expect(abs(reference[lane] - fixed[lane]) < 0.000001) }
    }

    @Test func mailboxNeverExposesMixedConcurrentSnapshots() async {
        let mailbox = PlaybackMeterMailbox()
        #expect(mailbox.latest() == nil)
        await withTaskGroup(of: Bool.self) { group in
            for (value, generation) in [(Float(0.2), UInt64(2)), (Float(0.8), UInt64(8))] {
                group.addTask {
                    for _ in 0..<10_000 { mailbox.publish(SIMD4(repeating: value), generation: generation) }
                    return true
                }
            }
            for _ in 0..<3 {
                group.addTask {
                    for _ in 0..<10_000 {
                        if let sample = mailbox.latest() {
                            let value = sample.bands.x
                            let generation: UInt64 = value == 0.2 ? 2 : 8
                            if sample.generation != generation || sample.bands != SIMD4(repeating: value) { return false }
                        }
                    }
                    return true
                }
            }
            for await consistent in group { #expect(consistent) }
        }
        // Contention must not leave the mailbox claimed permanently.
        mailbox.publish(SIMD4(repeating: 0.5), generation: 11)
        let final = mailbox.latest()
        #expect(final?.bands == SIMD4(repeating: 0.5))
        #expect(final?.generation == 11)
    }

    @Test func discardedStagingCannotReplaceTheCurrentIndex() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("index.json")
        let old = Data("old".utf8), new = Data(repeating: 42, count: 3_000_000)
        try old.write(to: target)
        let discarded = try await Task.detached { try StagedFileWrite.stage(new, beside: target) }.value
        StagedFileWrite.discard(discarded)
        #expect(try Data(contentsOf: target) == old)
        let accepted = try await Task.detached { try StagedFileWrite.stage(new, beside: target) }.value
        try StagedFileWrite.commit(accepted, to: target)
        #expect(try Data(contentsOf: target) == new)
        #expect(!FileManager.default.fileExists(atPath: accepted.path))
    }

    @Test func migrationCreatesAndFetchesContextsOnTheWorker() async throws {
        let source = try ModelContainer.cassette(inMemory: true)
        let target = try ModelContainer.listening(inMemory: true)
        let suite = "worker-migration-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        await Task.detached {
            AppContainer.migratePlaybackEventsIfNeeded(from: source, to: target, defaults: defaults, fetch: { context in
                #expect(!Thread.isMainThread)
                return try context.fetch(FetchDescriptor<PlaybackEvent>())
            })
        }.value
        #expect(defaults.bool(forKey: "cassette.listeningEventsMigrated.v1"))
    }
}
