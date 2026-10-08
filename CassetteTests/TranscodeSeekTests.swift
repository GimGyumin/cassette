import Foundation
import Testing
@testable import Cassette

struct TranscodeSeekTests {
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
    func setTranscodeClockForTest(offset: Double) {
        currentSource = .stream(URL(string: "https://example.invalid/rest/stream?format=aac")!,
                                customHeaders: [:], supportsTranscodeOffset: true)
        streamTimeOffset = offset
    }
}
