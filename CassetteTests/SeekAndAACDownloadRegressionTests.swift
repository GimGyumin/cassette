import Testing
import Foundation
import AVFoundation
import AudioStreaming
@testable import Cassette

@Suite("Finite stream seeking and explicit AAC downloads")
struct SeekAndAACDownloadRegressionTests {
    private func losslessFixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cassette-alac-\(UUID().uuidString).m4a")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 132_300))
        buffer.frameLength = buffer.frameCapacity
        for channel in 0..<2 {
            buffer.floatChannelData?[channel].initialize(repeating: 0, count: Int(buffer.frameLength))
        }
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatAppleLossless, AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 2, AVEncoderBitDepthHintKey: 16
        ])
        try file.write(from: buffer)
        return url
    }

    @Test(arguments: [128_000, 256_000])
    func explicitAACCannotSaveAServersLosslessResponse(bitRate: Int) async throws {
        let original = try losslessFixture()
        defer { try? FileManager.default.removeItem(at: original) }
        let result = try await AACDownloadEncoder.prepare(fileAt: original, bitRate: bitRate)
        defer { if result.url != original { try? FileManager.default.removeItem(at: result.url) } }
        #expect(result.wasEncoded)
        #expect(result.url != original)
        let encoded = try AVAudioFile(forReading: result.url)
        #expect(encoded.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatMPEG4AAC)
        #expect(encoded.processingFormat.channelCount == 2)
        #expect(Double(encoded.length) / encoded.processingFormat.sampleRate > 2.8)
        let preservedOriginal = try AVAudioFile(forReading: original)
        #expect(preservedOriginal.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatAppleLossless)
        // A valid AAC response at the requested ceiling is reused without another lossy encode.
        let reused = try await AACDownloadEncoder.prepare(fileAt: result.url, bitRate: bitRate)
        #expect(!reused.wasEncoded)
        #expect(reused.url == result.url)
    }

    @Test func nativeColdSeekWaitsForReadinessAndKeepsTheNewestPausedTarget() async throws {
        let original = try losslessFixture()
        defer { try? FileManager.default.removeItem(at: original) }
        let engine = AVPlayerPlaybackEngine()
        defer { engine.stop() }
        engine.start(url: original, headers: [:], generation: 5, position: 1, paused: true)
        engine.seek(to: 2)
        engine.seek(to: 0.5)
        engine.seek(to: 1.5)
        let deadline = Date().addingTimeInterval(5)
        while engine.isSeeking, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!engine.isSeeking)
        #expect(abs(engine.progress - 1.5) < 0.1)
        #expect(engine.state == .paused)
    }

    @Test @MainActor func finiteSourceAcceptsSeekingBeforeAnEngineHasSeekMetadata() async throws {
        let original = try losslessFixture()
        defer { try? FileManager.default.removeItem(at: original) }
        let fake = FakePlaybackEngine()
        fake.duration = 3
        fake.isSeekable = false
        let container = try AppContainer(inMemory: true, engine: fake)
        let service = try #require(container.playerService as? PlayerService)
        container.playerState.currentTrack = DisplayableSong(id: "seek", title: "Seek", duration: 3)
        container.playerState.duration = 3
        container.playerState.playbackState = .paused
        await service.setFiniteStreamFixture(original)
        await service.seek(to: 1.5)
        #expect(container.playerState.position == 1.5)
        #expect(container.playerState.isSeekable)
        #expect(service.systemEngine.hasCurrentItem)
        let deadline = Date().addingTimeInterval(5)
        while service.systemEngine.isSeeking, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(abs(await service.engineProgress() - 1.5) < 0.1)
        #expect(container.playerState.playbackState == .paused)
        await service.stop()
    }

    @Test @MainActor func aCompleteResponseRestoresTheTargetAndIsRemovedOnStop() async throws {
        let complete = try losslessFixture()
        defer { try? FileManager.default.removeItem(at: complete) }
        let container = try AppContainer(inMemory: true, engine: FakePlaybackEngine())
        let service = try #require(container.playerService as? PlayerService)
        container.playerState.currentTrack = DisplayableSong(id: "buffer", title: "Buffer", duration: 3)
        container.playerState.duration = 3
        container.playerState.position = 1.5
        container.playerState.playbackState = .paused
        let origin = try #require(URL(string: "https://server.invalid/rest/stream?format=raw"))
        let response = try #require(HTTPURLResponse(url: origin, statusCode: 200,
            httpVersion: nil, headerFields: ["Content-Type": "audio/mp4"]))
        let fence = await service.prepareBufferedSeekFixture(origin, target: 1.5)
        // A completed obsolete acquisition must not replace the newest seek or move its file.
        try await service.restoreSeekFromBuffer(temporary: complete, response: response, target: 1.5,
            epoch: fence.0, request: fence.1 &- 1, intendsToPlay: false, originalSuffix: "m4a")
        #expect(FileManager.default.fileExists(atPath: complete.path))
        #expect(!service.systemEngine.hasCurrentItem)
        try await service.restoreSeekFromBuffer(temporary: complete, response: response, target: 1.5,
            epoch: fence.0, request: fence.1, intendsToPlay: false, originalSuffix: "m4a")
        let buffered = try #require(await service.bufferedSeekURLForTest())
        #expect(FileManager.default.fileExists(atPath: buffered.path))
        #expect(!FileManager.default.fileExists(atPath: complete.path))
        let deadline = Date().addingTimeInterval(5)
        while service.systemEngine.isSeeking, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(abs(await service.engineProgress() - 1.5) < 0.1)
        #expect(service.systemEngine.state == .paused)
        await service.seek(to: 0.5)
        await service.seek(to: 2)
        let secondDeadline = Date().addingTimeInterval(5)
        while service.systemEngine.isSeeking, Date() < secondDeadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(abs(await service.engineProgress() - 2) < 0.1)
        #expect(container.playerState.position == 2)
        await service.stop()
        #expect(!FileManager.default.fileExists(atPath: buffered.path))
    }
}

private extension PlayerService {
    func setFiniteStreamFixture(_ url: URL) { currentSource = .stream(url, customHeaders: [:]) }
    func prepareBufferedSeekFixture(_ url: URL, target: Double) -> (UInt64, UInt64) {
        currentSource = .stream(url, customHeaders: [:])
        seekRequestGeneration &+= 1
        seekState = .settling(target: target, deadline: Date().addingTimeInterval(600))
        return (playbackEpoch, seekRequestGeneration)
    }
    func bufferedSeekURLForTest() -> URL? { seekBufferURL }
}
