import Foundation
import Testing
@testable import Cassette

struct JellyfinClientURLTests {
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
