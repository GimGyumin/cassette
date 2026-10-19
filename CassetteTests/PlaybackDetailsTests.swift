import Foundation
import Testing
@testable import Cassette

struct PlaybackDetailsTests {
    @Test func describesResolvedRouteInsteadOfSelectedQuality() throws {
        let cases: [(String, PlaybackDetails.Method, String?, Int?)] = [
            ("/rest/stream?format=raw", .openSubsonic, nil, nil),
            ("/proxy/rest/stream.view?format=aac&maxBitRate=128", .openSubsonic, "AAC", 128),
            ("/Audio/track/universal?AudioCodec=flac&Static=false", .universalTranscoding, "FLAC", nil),
            ("/Audio/track/stream.aac?Static=false&AudioCodec=aac", .universalTranscoding, "AAC", nil),
            ("/Audio/track/stream.aac?Static=false", .universalTranscoding, nil, nil),
            ("/Audio/track/universal?Static=true&AudioCodec=aac", .directPlay, nil, nil),
            ("/Audio/track/main.m3u8?AudioCodec=aac&MaxStreamingBitrate=256000", .hls, "AAC", 256),
            ("/jellyfin/Items/track/File?api_key=secret", .originalFile, nil, nil),
            ("/rest/stream", .openSubsonic, nil, nil),
            ("/unknown", .serverDefault, nil, nil),
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

    @Test func resolvedRouteSurvivesProxyURLsAndRetainsOriginalNames() throws {
        let routes: [(JellyfinPlaybackRoute, PlaybackDetails.Method, String)] = [
            (.directPlay, .directPlay, "Direct Play"),
            (.universal, .universalTranscoding, "Universal Transcoding"),
            (.hls, .hls, "HLS"),
            (.originalFile, .originalFile, "Original File"),
            (.openSubsonic, .openSubsonic, "OpenSubsonic"),
        ]
        for (route, method, name) in routes {
            let context = JellyfinPlaybackContext(itemID: "track", mediaSourceID: nil,
                playSessionID: "secret", playMethod: .transcode, route: route)
            let source = MediaSource.stream(try #require(URL(string: "https://proxy.example.com/opaque?api_key=secret")),
                customHeaders: ["Authorization": "secret"], jellyfin: context)
            let details = PlaybackDetails(source: source, usesSystemPlayer: true)
            #expect(details.method == method)
            #expect(details.method.rawValue == name)
            #expect(details.method.usesOriginalName)
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
