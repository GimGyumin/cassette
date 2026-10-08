import Foundation
import SwiftData
import SwiftSonic
import Testing
@testable import Cassette

nonisolated private final class JellyfinMusicURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            #expect(request.url?.path.contains("/rest/") == false)
            #expect(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "jwt" } != true)
            let (status, data) = try Self.handler?(request) ?? (500, Data())
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@Suite(.serialized)
@MainActor
struct JellyfinMusicTransportTests {
    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [JellyfinMusicURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func musicClient() throws -> SwiftSonicClient {
        let url = URL(string: "https://music.example.com/proxy")!
        let client = try JellyfinClient(serverBaseURL: url, accessToken: "jellyfin-only-token", deviceID: "test", session: session())
        return JellyfinMusicTransport(client: client, user: JellyfinUser(id: "user", name: "alice")).makeMusicClient(serverURL: url)
    }

    private func json(_ object: Any) throws -> (Int, Data) {
        (200, try JSONSerialization.data(withJSONObject: object))
    }

    @Test func quickConnectAlbumRecoversRepresentativeQualityFromPlaybackInfo() async throws {
        let client = try musicClient()
        var playbackRequests = 0
        JellyfinMusicURLProtocol.handler = { request in
            let path = request.url!.path
            if path.hasSuffix("/Users/user/Items/album") {
                return (200, Data(#"{"Id":"album","Name":"Collection","Type":"MusicAlbum","AlbumArtist":"","AlbumArtists":[{"Name":"Various Artists","Id":"various"}]}"#.utf8))
            }
            if path.hasSuffix("/Users/user/Items") {
                return (200, Data(#"{"Items":[{"Id":"song-1","Name":"First","Type":"Audio","Artists":["Singer A"]},{"Id":"song-2","Name":"Second","Type":"Audio","Artists":["Singer B"]}],"TotalRecordCount":2}"#.utf8))
            }
            if path.hasSuffix("/Items/song-1/PlaybackInfo") {
                playbackRequests += 1
                return (200, Data(#"{"MediaSources":[{"Container":"flac","Bitrate":937000,"MediaStreams":[{"Type":"Audio","Codec":"flac","SampleRate":44100,"BitDepth":16,"Channels":2}]}]}"#.utf8))
            }
            Issue.record("Unexpected route: \(path)")
            return (404, Data())
        }
        let album = try await client.getAlbum(id: "album")
        #expect(album.artist == "Various Artists")
        #expect(album.song?.first?.bitRate == 937)
        #expect(album.song?.first?.samplingRate == 44_100)
        #expect(album.song?.first?.bitDepth == 16)
        #expect(playbackRequests == 1)
    }

    @Test func approvedQuickConnectPersistsPasswordlessAccountAndLoadsMusic() async throws {
        let container = try ModelContainer.cassette(inMemory: true)
        let state = ServerState()
        let keychain = MockKeychain()
        let session = session()
        defer { session.invalidateAndCancel() }
        let server = ServerService(state: state, keychain: keychain, modelContainer: container, cacheService: MockCacheService(), jellyfinSession: session)
        let jellyfin = JellyfinService(serverService: server, keychain: keychain, modelContainer: container,
            deviceIdentity: .init(id: "test", name: "Mac", clientName: "Cassette", clientVersion: "1"), session: session)
        JellyfinMusicURLProtocol.handler = { request in
            let path = request.url!.path
            if path.hasSuffix("/QuickConnect/Enabled") { return (200, Data("true".utf8)) }
            if path.hasSuffix("/QuickConnect/Initiate") {
                return (200, Data(#"{"Code":"123456","Secret":"one-use-secret","Authenticated":false}"#.utf8))
            }
            if path.hasSuffix("/QuickConnect/Connect") { return (200, Data(#"{"Authenticated":true}"#.utf8)) }
            if path.hasSuffix("/Users/AuthenticateWithQuickConnect") {
                #expect(request.httpMethod == "POST")
                return (200, Data(#"{"AccessToken":"jellyfin-only-token","User":{"Id":"user","Name":"alice"}}"#.utf8))
            }
            #expect(request.value(forHTTPHeaderField: "X-Emby-Token") == "jellyfin-only-token")
            if path.hasSuffix("/Users/Me") { return (200, Data(#"{"Id":"user","Name":"alice"}"#.utf8)) }
            if path.hasSuffix("/Users/user/Items") {
                return (200, Data(#"{"Items":[{"Id":"album","Name":"Album","Type":"MusicAlbum","ChildCount":2}],"TotalRecordCount":1}"#.utf8))
            }
            Issue.record("Unexpected route: \(path)")
            return (404, Data())
        }
        let model = OnboardingViewModel(serverService: server, jellyfinService: jellyfin)
        model.serverURL = "https://music.example.com/proxy"
        #expect(await model.signInWithQuickConnect())
        let credentials = try await server.activeCredentials()
        #expect(credentials.password.isEmpty)
        #expect(credentials.jellyfinAccessToken == "jellyfin-only-token")
        #expect(state.activeServer?.username == "alice")
        let client = try await server.makeSwiftSonicClient()
        try await client.ping()
        let albums = try await client.getAlbumList2(type: .newest)
        #expect(albums.first?.name == "Album")
        #expect(albums.first?.songCount == 2)
    }

    @Test func searchFillsServerCappedPagesAndPreservesOffset() async throws {
        let client = try musicClient()
        JellyfinMusicURLProtocol.handler = { request in
            let query = Dictionary(uniqueKeysWithValues: URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
            #expect(query["SearchTerm"] == "inst")
            #expect(query["IncludeItemTypes"] == "Audio")
            let offset = Int(query["StartIndex"]!)!
            let items = (offset..<min(offset + min(2, Int(query["Limit"]!)!), 9)).map { ["Id": "song-\($0)", "Name": "inst \($0)", "Type": "Audio"] }
            return (200, try JSONSerialization.data(withJSONObject: ["Items": items, "TotalRecordCount": 9]))
        }
        let results = try await client.search3("inst", artistCount: 0, albumCount: 0, songCount: 5, songOffset: 3)
        #expect(results.song?.map(\.id) == ["song-3", "song-4", "song-5", "song-6", "song-7"])
    }

    @Test func mediaURLsStayOnJellyfinAndOriginalCoverHasNoResize() async throws {
        let client = try musicClient()
        let guid = "1234567890abcdef1234567890abcdef"
        let id = try #require(NavidromeJellyfinIDCodec.canonicalID(fromJellyfinGUID: guid))
        let original = try #require(client.coverArtURL(id: id))
        #expect(original.path == "/proxy/jellyfin/Items/\(guid)/Images/Primary")
        #expect(!original.absoluteString.contains("MaxWidth"))
        let thumbnail = try #require(client.coverArtURL(id: id, size: 160))
        #expect(thumbnail.absoluteString.contains("MaxWidth=160"))
        let stream = try #require(client.streamURL(id: id, format: "raw"))
        #expect(stream.path == "/proxy/jellyfin/Items/\(guid)/File")
        let download = try #require(client.downloadURL(id: id))
        #expect(download.path == "/proxy/jellyfin/Items/\(guid)/Download")
        let transcode = try #require(client.streamURL(id: id, maxBitRate: 192, format: "aac"))
        #expect(transcode.path == "/proxy/jellyfin/Audio/\(guid)/stream.aac")
        #expect(transcode.absoluteString.contains("AudioBitRate=192000"))
        #expect(transcode.absoluteString.contains("Static=false"))
        #expect(transcode.absoluteString.contains("CopyTimestamps=false"))
    }

    @Test func removingDuplicateTrackUsesOccurrenceID() async throws {
        let client = try musicClient()
        JellyfinMusicURLProtocol.handler = { request in
            #expect(request.url?.path == "/proxy/jellyfin/Playlists/playlist/Items")
            if request.httpMethod == "GET" {
                return (200, Data(#"{"Items":[{"Id":"same-song","Name":"Song","PlaylistItemId":"entry-first"},{"Id":"same-song","Name":"Song","PlaylistItemId":"entry-second"}],"TotalRecordCount":2}"#.utf8))
            }
            #expect(request.httpMethod == "DELETE")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            #expect(query?.first { $0.name == "EntryIds" }?.value == "entry-second")
            return (204, Data())
        }
        try await client.updatePlaylist(id: "playlist", songIndexesToRemove: [1])
    }

    @Test func lyricsConvertJellyfinTicksToMilliseconds() async throws {
        let client = try musicClient()
        JellyfinMusicURLProtocol.handler = { request in
            #expect(request.url?.path == "/proxy/jellyfin/Audio/song/Lyrics")
            return (200, Data(#"{"Metadata":{"IsSynced":true},"Lyrics":[{"Text":"Hello","Start":12500000}]}"#.utf8))
        }
        let lyrics = try await client.getLyricsBySongId(id: "song")
        #expect(lyrics.structuredLyrics.first?.line.first?.start == 1250)
        #expect(lyrics.structuredLyrics.first?.synced == true)
    }

    @Test func playlistMetadataAndTracksUseTheirDistinctResponses() async throws {
        let client = try musicClient()
        JellyfinMusicURLProtocol.handler = { request in
            switch request.url!.path {
            case "/proxy/jellyfin/Users/user/Items/playlist":
                return (200, Data(#"{"Id":"playlist","Name":"My List","Type":"Playlist","ChildCount":1}"#.utf8))
            case "/proxy/jellyfin/Playlists/playlist":
                return (200, Data(#"{"OpenAccess":true,"ItemIds":["song"],"Shares":[]}"#.utf8))
            case "/proxy/jellyfin/Playlists/playlist/Items":
                return (200, Data(#"{"Items":[{"Id":"song","Name":"Song","RunTimeTicks":1200000000,"PlaylistItemId":"entry"}],"TotalRecordCount":1}"#.utf8))
            default:
                Issue.record("Unexpected playlist route")
                return (404, Data())
            }
        }
        let playlist = try await client.getPlaylist(id: "playlist")
        #expect(playlist.name == "My List")
        #expect(playlist.isPublic == true)
        #expect(playlist.songCount == 1)
        #expect(playlist.duration == 120)
        #expect(playlist.entry?.first?.title == "Song")
    }

    @Test func lyricCapabilityIsExposedByTheLocalAdapter() async throws {
        let client = try musicClient()
        JellyfinMusicURLProtocol.handler = { request in
            #expect(request.url?.path.hasSuffix("/Users/Me") == true)
            return (200, Data(#"{"Id":"user","Name":"alice"}"#.utf8))
        }
        let capabilities = try await client.loadCapabilities()
        #expect(capabilities.supports(.songLyrics))
        #expect(!capabilities.supports(.playbackReport))
    }

    @Test func rejectedTokenDoesNotPersistServer() async throws {
        let container = try ModelContainer.cassette(inMemory: true)
        let state = ServerState()
        let server = ServerService(state: state, keychain: MockKeychain(), modelContainer: container, cacheService: MockCacheService(), jellyfinSession: session())
        JellyfinMusicURLProtocol.handler = { _ in (401, Data()) }
        await #expect(throws: (any Error).self) {
            try await server.addServerWithJellyfinToken(displayName: "Server", baseURL: "https://music.example.com", username: "alice", jellyfinAccessToken: "rejected", customHeaders: [:])
        }
        #expect(state.servers.isEmpty)
    }
}
