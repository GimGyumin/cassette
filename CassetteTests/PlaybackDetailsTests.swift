import Foundation
import Testing
@testable import Cassette

struct PlaybackDetailsTests {
    @Test func describesResolvedRouteInsteadOfSelectedQuality() throws {
        let cases: [(String, PlaybackDetails.Method, String?, Int?)] = [
            ("/rest/stream?format=raw", .original, nil, nil),
            ("/rest/stream?format=aac&maxBitRate=128", .converted, "AAC", 128),
            ("/Audio/track/universal?AudioCodec=flac&Static=false", .converted, "FLAC", nil),
            ("/Audio/track/universal?Static=true&AudioCodec=aac", .original, nil, nil),
            ("/Audio/track/main.m3u8?AudioCodec=aac&MaxStreamingBitrate=256000", .hls, "AAC", 256),
            ("/jellyfin/Items/track/File?api_key=secret", .original, nil, nil),
            ("/rest/stream", .serverDefault, nil, nil),
        ]
        for (path, method, codec, limit) in cases {
            let url = try #require(URL(string: "https://music.example.com" + path))
            let details = PlaybackDetails(source: .stream(url, customHeaders: ["Authorization": "secret"]), usesSystemPlayer: true)
            #expect(details.location == .server)
            #expect(details.method == method)
            #expect(details.requestedCodec == codec)
            #expect(details.bitRateLimitKbps == limit)
            #expect(details.engine == "AVPlayer")
            #expect(!String(describing: details).contains("secret"))
        }
    }

    @Test func localAndRadioSourcesDoNotInheritCatalogQualityOrNetworkSettings() {
        let cached = PlaybackDetails(source: .cached(URL(fileURLWithPath: "/tmp/track.aac")), usesSystemPlayer: false)
        #expect(cached.location == .cached)
        #expect(cached.method == .local)
        #expect(cached.localFileFormat == "AAC")
        #expect(cached.requestedCodec == nil)
        #expect(cached.engine == "AudioStreaming")
        let downloaded = PlaybackDetails(source: .downloaded(URL(fileURLWithPath: "/tmp/track.bin")), usesSystemPlayer: true)
        #expect(downloaded.location == .downloaded)
        #expect(downloaded.localFileFormat == nil)
        let radio = PlaybackDetails(source: .liveStream(URL(string: "https://radio.example.com/live")!, customHeaders: [:], stationId: "radio"), usesSystemPlayer: true)
        #expect(radio.location == .radio)
        #expect(radio.method == .radio)
        #expect(radio.requestedCodec == nil)
    }
}
