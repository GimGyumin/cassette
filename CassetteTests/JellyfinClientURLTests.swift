import Foundation
import Testing
@testable import Cassette

struct JellyfinClientURLTests {
    @Test func negotiatedTranscodeKeepsSessionAndServerPrefix() throws {
        let client = try JellyfinClient(serverBaseURL: #require(URL(string: "https://music.example.com/navidrome")),
                                        accessToken: "test-token", deviceID: "test-device")
        for path in ["Audio/track/main.m3u8", "/Audio/track/main.m3u8", "/navidrome/jellyfin/Audio/track/main.m3u8"] {
            let url = try #require(client.transcodingStreamURL(path + "?PlaySessionId=session&AudioBitrate=128000"))
            #expect(url.path == "/navidrome/jellyfin/Audio/track/main.m3u8")
            let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
            #expect(query.contains(URLQueryItem(name: "PlaySessionId", value: "session")))
            #expect(query.contains(URLQueryItem(name: "AudioBitrate", value: "128000")))
            #expect(query.contains(URLQueryItem(name: "api_key", value: "test-token")))
        }
        #expect(client.transcodingStreamURL("https://other.example.com/Audio/track/main.m3u8") == nil)
        #expect(client.transcodingStreamURL("//other.example.com/Audio/track/main.m3u8") == nil)
        #expect(client.transcodingStreamURL("http://music.example.com/Audio/track/main.m3u8") == nil)
    }

    @Test func directStreamExplicitlyRequestsOriginalBytes() throws {
        let client = try JellyfinClient(serverBaseURL: #require(URL(string: "https://music.example.com")), deviceID: "test")
        let url = try #require(client.directStreamURL(itemID: "track", container: "flac"))
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains(
            URLQueryItem(name: "Static", value: "true")) == true)
    }
    @Test func rootURLAppendsJellyfinExactlyOnce() throws {
        let root = try #require(URL(string: "https://music.example.com/"))
        #expect(JellyfinClient.jellyfinBaseURL(from: root)?.absoluteString == "https://music.example.com/jellyfin")
    }

    @Test func explicitJellyfinURLIsNotDuplicated() throws {
        let endpoint = try #require(URL(string: "https://music.example.com/jellyfin"))
        #expect(JellyfinClient.jellyfinBaseURL(from: endpoint)?.absoluteString == "https://music.example.com/jellyfin")
    }

    @Test func subpathServerPreservesBasePath() throws {
        let root = try #require(URL(string: "https://music.example.com/navidrome/"))
        #expect(JellyfinClient.jellyfinBaseURL(from: root)?.absoluteString == "https://music.example.com/navidrome/jellyfin")
    }
}
