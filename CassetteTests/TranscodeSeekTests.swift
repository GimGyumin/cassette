import Foundation
import AVFoundation
import AudioStreaming
import Testing
@testable import Cassette

struct TranscodeSeekTests {
    @Test func universalOffsetFallbackPreservesQualityAndUsesAnExplicitRelativeClock() throws {
        let client = try JellyfinClient(serverBaseURL: #require(URL(string: "https://music.example/proxy")),
            accessToken: "token", deviceID: "device")
        let url = try #require(client.universalAudioURL(itemID: "track", container: "aac", audioCodec: "aac",
            maxStreamingBitrate: 256_000, mediaSourceID: "source", playSessionID: "session", staticStream: false))
        let source = MediaSource.stream(url, customHeaders: ["X-Proxy": "preserved"])
        let request = try #require(source.transcodeRequest(at: 90.5))
        let query = try #require(URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(request.url.path == "/proxy/jellyfin/Audio/track/stream.aac")
        #expect(request.offset == 90.5)
        for (key, value) in [("StartTimeTicks", "905000000"), ("AudioBitRate", "256000"),
                             ("DeviceId", "device"), ("MediaSourceId", "source"), ("PlaySessionId", "session"),
                             ("api_key", "token"), ("CopyTimestamps", "false")] {
            #expect(query.first { $0.name == key }?.value == value)
        }
        #expect(source.customHeaders["X-Proxy"] == "preserved")
    }
    @Test func navidromeSeekPreservesCodecAuthenticationAndProxyPrefix() throws {
        let url = try #require(URL(string: "https://music.example/proxy/rest/stream?id=track&format=aac&maxBitRate=256&u=user&t=token&s=salt&timeOffset=10"))
        let source = MediaSource.stream(url, customHeaders: ["X-Proxy": "value"], supportsTranscodeOffset: true)
        let request = try #require(source.transcodeRequest(at: 62.9))
        let query = try #require(URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(request.offset == 62)
        #expect(request.url.path == url.path)
        #expect(query.filter { $0.name == "timeOffset" }.map(\.value) == ["62"])
        for key in ["id", "format", "maxBitRate", "u", "t", "s"] {
            let original = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == key }
            #expect(query.first { $0.name == key } == original)
        }
        #expect(source.customHeaders["X-Proxy"] == "value")
        #expect(source.transcodeRequest(at: .nan) == nil)
        #expect(source.transcodeRequest(at: .infinity) == nil)
        #expect(source.transcodeRequest(at: -5)?.offset == 0)
        #expect(!MediaSource.stream(url, customHeaders: [:]).supportsTranscodeOffset)
        #expect(MediaSource.downloaded(url).transcodeRequest(at: 60) == nil)
    }

    @Test func jellyfinAACUsesMediaTicksAndKeepsAZeroBasedEncoderClock() throws {
        let client = try JellyfinClient(serverBaseURL: #require(URL(string: "https://music.example/proxy")),
                                       accessToken: "token", deviceID: "device")
        let url = try #require(client.progressiveAudioURL(itemID: "track", container: "aac", audioCodec: "aac",
            audioBitRate: 256_000, mediaSourceID: "source", playSessionID: "session", startTimeTicks: 10))
        let source = MediaSource.stream(url, customHeaders: [:])
        #expect(source.supportsTranscodeOffset)
        let request = try #require(source.transcodeRequest(at: 62.5))
        let query = try #require(URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(request.offset == 62.5)
        #expect(request.url.path == "/proxy/jellyfin/Audio/track/stream.aac")
        #expect(query.filter { $0.name == "StartTimeTicks" }.map(\.value) == ["625000000"])
        for (key, value) in [("AudioBitRate", "256000"), ("AudioCodec", "aac"), ("CopyTimestamps", "false"),
                             ("Static", "false"), ("MediaSourceId", "source"), ("PlaySessionId", "session"),
                             ("api_key", "token"), ("AllowAudioStreamCopy", "false")] {
            #expect(query.first { $0.name == key }?.value == value)
        }
        let raw = try #require(client.directStreamURL(itemID: "track", container: "aac"))
        #expect(!MediaSource.stream(raw, customHeaders: [:]).supportsTranscodeOffset)
        let hls = try #require(client.hlsURL(itemID: "track", audioCodec: "aac"))
        #expect(!MediaSource.stream(hls, customHeaders: [:]).supportsTranscodeOffset)
    }

    @Test func oneSecondEncoderResponsesCannotCompleteOrRepeatAMinuteLongSong() {
        #expect(PlayerService.isPrematureTranscodeEnd(duration: 180, offset: 0, position: 1))
        #expect(PlayerService.isPrematureTranscodeEnd(duration: 180, offset: 60, position: 61))
        #expect(!PlayerService.isPrematureTranscodeEnd(duration: 61, offset: 60, position: 61))
        #expect(!PlayerService.isPrematureTranscodeEnd(duration: 180, offset: 0, position: 179))
        #expect(!PlayerService.isPrematureTranscodeEnd(duration: .nan, offset: 0, position: 1))
    }
}

@MainActor
struct TranscodeClockTests {
    @Test func cancelledProgressTickCannotResetTheLatestScrubsEOFClock() async throws {
        let container = try AppContainer(inMemory: true, engine: FakePlaybackEngine())
        let service = try #require(container.playerService as? PlayerService)
        let song = DisplayableSong(id: "cancelled-tick", title: "Tick", duration: 180)
        container.playerState.currentTrack = song
        container.playerState.queue = [song]
        container.playerState.duration = 180
        container.playerState.position = 90
        container.playerState.playbackState = .playing
        await service.setPreviousEOFClockForTest(90)
        let obsoleteTick = Task { await service.checkEndOfTrackFallback(progress: 0) }
        obsoleteTick.cancel()
        await obsoleteTick.value
        #expect(await service.previousEOFClockForTest() == 90)
        #expect(container.playerState.position == 90)
        #expect(container.playerState.playbackState == .playing)
        await service.stop()
    }

    @Test(arguments: ["m4a", "aac"])
    func repeatedOffsetScrubsKeepNativePlaybackActiveAndRejectObsoleteEvents(encoding: String) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("scrubs-\(UUID()).\(encoding)")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 220_500))
        buffer.frameLength = buffer.frameCapacity
        buffer.floatChannelData?.pointee.initialize(repeating: 0, count: Int(buffer.frameLength))
        // A finite, silent AAC file exercises actual native item replacement without a server.
        if encoding == "aac" {
            // FFmpeg-generated silence in ADTS, the progressive AAC container used by servers.
            let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("Fixtures/SilentAAC.adts")
            try FileManager.default.copyItem(at: fixture, to: url)
        } else {
            let file = try AVAudioFile(forWriting: url, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 128_000
            ])
            try file.write(from: buffer)
        }
        let engine = FakePlaybackEngine()
        let container = try AppContainer(inMemory: true, engine: engine)
        let service = try #require(container.playerService as? PlayerService)
        let song = DisplayableSong(id: "scrubs", title: "Scrubs", duration: 180)
        container.playerState.currentTrack = song
        container.playerState.queue = [song]
        container.playerState.duration = 180
        container.playerState.playbackState = .playing
        await service.prepareOffsetScrubsForTest(url: url)
        var priorGeneration: UInt64 = 0
        for target in [40.0, 10, 70, 5, 80, 20] {
            priorGeneration = await service.nativeGenerationForTest()
            await service.seek(to: target)
            #expect(container.playerState.position == target)
            #expect(container.playerState.playbackState.hasPlaybackIntent)
            #expect(await service.engineProgress() >= target)
            #expect(service.systemEngine.hasCurrentItem)
            #expect(await service.nativeGenerationForTest() > priorGeneration)
        }
        let currentItem = try #require(service.systemEngine.observedItemID)
        // A failed/cancelled response from the previous scrub cannot stop the replacement.
        await service.handleSystemEngineEvent(.failed(priorGeneration, currentItem, .classify(nil)))
        await service.handleSystemEngineEvent(.ended(priorGeneration, currentItem))
        #expect(service.systemEngine.hasCurrentItem)
        #expect(container.playerState.playbackState.hasPlaybackIntent)
        let deadline = Date().addingTimeInterval(3)
        // The native clock and MainActor's seek-settlement publication are asynchronous.
        // Wait for both; a clock sample alone can precede the .playing update by one tick.
        while Date() < deadline {
            if await service.engineProgress() > 20.1,
               container.playerState.playbackState == .playing { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(await service.engineProgress() > 20.1)
        #expect(container.playerState.playbackState == .playing)
        #expect(!engine.calls.contains { if case .play = $0 { return true }; return false })
        await service.pause()
        await service.seek(to: 50)
        await service.seek(to: 15)
        #expect(container.playerState.playbackState == .paused)
        #expect(container.playerState.position == 15)
        #expect(service.systemEngine.state == .paused)
        await service.stop()
    }

    @Test func repeatOneResetsThePreviousEOFClockBeforeReopening() async throws {
        let engine = FakePlaybackEngine()
        engine.progress = 180
        engine.duration = 180
        let container = try AppContainer(inMemory: true, engine: engine)
        let service = try #require(container.playerService as? PlayerService)
        let song = DisplayableSong(id: "repeat", title: "Repeat", duration: 180)
        container.playerState.currentTrack = song
        container.playerState.queue = [song]
        container.playerState.duration = 180
        container.playerState.position = 180
        container.playerState.repeatMode = .one
        container.playerState.playbackState = .playing
        await service.prepareRepeatClockForTest()
        await service.handleEndOfTrack(engineConfirmed: true)
        #expect(container.playerState.position == 0)
        #expect(await service.previousEOFClockForTest() == 0)
        #expect(container.playerState.currentTrack?.id == song.id)
        await service.stop()
    }

    @Test func offsetResponsesKeepAbsoluteProgressDurationAndResetWhenStopped() async throws {
        let engine = FakePlaybackEngine()
        engine.progress = 1.5
        engine.duration = 120
        let container = try AppContainer(inMemory: true, engine: engine)
        let service = try #require(container.playerService as? PlayerService)
        await service.setTranscodeClockForTest(offset: 60)
        #expect(await service.engineProgress() == 61.5)
        #expect(await service.engineDuration() == 180)
        #expect(await service.engineIsSeekable())
        await service.seekEngine(to: 75)
        #expect(engine.calls.contains(.seek(15)))
        // A backward scrub creates a new response, so offsets replace rather than accumulate.
        await service.setTranscodeClockForTest(offset: 10)
        #expect(await service.engineProgress() == 11.5)
        await service.stopEngine()
        #expect(await service.engineProgress() == 1.5)
    }
}

private extension PlayerService {
    func setPreviousEOFClockForTest(_ progress: Double) { lastObservedEngineProgress = progress }
    func prepareOffsetScrubsForTest(url: URL) {
        currentSource = .stream(url, customHeaders: [:], supportsTranscodeOffset: true)
    }

    func nativeGenerationForTest() -> UInt64 { systemPlayback.generation }
    func prepareRepeatClockForTest() {
        currentSource = .downloaded(URL(fileURLWithPath: "/tmp/cassette-repeat-clock-test.aac"))
        lastObservedEngineProgress = 180
    }

    func previousEOFClockForTest() -> Double { lastObservedEngineProgress }

    func setTranscodeClockForTest(offset: Double) {
        currentSource = .stream(URL(string: "https://example.invalid/rest/stream?format=aac")!,
                                customHeaders: [:], supportsTranscodeOffset: true)
        streamTimeOffset = offset
    }
}
