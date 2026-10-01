import Foundation
import Testing
@testable import Cassette

nonisolated private final class JellyfinFeatureURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let (status, data) = try Self.handler?(request) ?? (500, Data())
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

/// `URLSession` may hand a request body to `URLProtocol` as a stream instead of
/// `httpBody`, so tests must read whichever representation the system provides.
private func requestBodyData(of request: URLRequest) -> Data? {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return nil }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
        let read = stream.read(&buffer, maxLength: buffer.count)
        if read <= 0 { break }
        data.append(buffer, count: read)
    }
    return data
}

@Suite(.serialized)
struct JellyfinFeatureClientTests {
    private func makeClient() throws -> JellyfinClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [JellyfinFeatureURLProtocol.self]
        return try JellyfinClient(
            serverBaseURL: #require(URL(string: "https://music.example.com")),
            accessToken: "token",
            deviceID: "device",
            session: URLSession(configuration: configuration)
        )
    }

    @Test func collectionQueryCarriesSearchFiltersSortAndPaging() async throws {
        let client = try makeClient()
        JellyfinFeatureURLProtocol.handler = { request in
            let url = try #require(request.url)
            let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
            let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            #expect(components.path == "/jellyfin/Users/user/Items")
            #expect(query["ParentId"] == "library")
            #expect(query["IncludeItemTypes"] == "MusicArtist,MusicAlbum,Audio,Playlist")
            #expect(query["SearchTerm"] == "hello world")
            #expect(query["Filters"] == "IsFavorite,IsPlayed")
            #expect(query["SortBy"] == "SortName,ProductionYear")
            #expect(query["SortOrder"] == "Descending")
            #expect(query["StartIndex"] == "20")
            #expect(query["Limit"] == "50")
            return (200, Data(#"{"Items":[],"TotalRecordCount":0}"#.utf8))
        }

        var query = JellyfinItemsQuery()
        query.parentID = "library"
        query.includeItemTypes = [.musicArtist, .musicAlbum, .audio, .playlist]
        query.searchTerm = "hello world"
        query.filters = [.favorite, .played]
        query.sortBy = ["SortName", "ProductionYear"]
        query.sortOrder = .descending
        query.startIndex = 20
        query.limit = 50
        _ = try await client.items(userID: "user", query: query)
    }

    @Test func playbackURLsCoverDirectUniversalHLSOriginalAndDownload() throws {
        let client = try makeClient()
        let direct = client.directStreamURL(itemID: "song", container: "flac", mediaSourceID: "media", playSessionID: "session")
        let universal = client.universalAudioURL(itemID: "song", audioCodec: "aac", maxStreamingBitrate: 192_000, mediaSourceID: "media", playSessionID: "session")
        let hls = client.hlsURL(itemID: "song", audioCodec: "aac", mediaSourceID: "media", playSessionID: "session")
        let original = client.originalFileURL(itemID: "song", mediaSourceID: "media", playSessionID: "session")
        #expect(direct?.path == "/jellyfin/Audio/song/stream.flac")
        #expect(universal?.path == "/jellyfin/Audio/song/universal")
        #expect(hls?.path == "/jellyfin/Audio/song/main.m3u8")
        #expect(original?.path == "/jellyfin/Items/song/File")
        #expect(client.downloadURL(itemID: "song")?.path == "/jellyfin/Items/song/Download")
        for url in [direct, universal, hls, original].compactMap({ $0 }) {
            let query = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map { ($0.name, $0.value ?? "") } ?? [])
            #expect(query["MediaSourceId"] == "media")
            #expect(query["PlaySessionId"] == "session")
            #expect(query["DeviceId"] == "device")
            #expect(query["api_key"] == "token")
        }
    }

    @Test func lyricsDecodeWordTimedCues() async throws {
        let client = try makeClient()
        JellyfinFeatureURLProtocol.handler = { request in
            #expect(request.url?.path == "/jellyfin/Audio/song/Lyrics")
            return (200, Data(#"{"Metadata":{"IsSynced":true},"Lyrics":[{"Text":"hello world","Start":100,"Cues":[{"Position":0,"EndPosition":5,"Start":100,"End":200},{"Position":6,"EndPosition":11,"Start":200,"End":300}]}]}"#.utf8))
        }
        let result = try await client.lyrics(itemID: "song")
        #expect(result.lyrics?.first?.cues?.count == 2)
        #expect(result.lyrics?.first?.cues?.last?.position == 6)
        #expect(result.lyrics?.first?.cues?.last?.endPosition == 11)
        #expect(result.metadata?.isSynced == true)
    }

    @Test func playlistContainersPositionRatingAndPlaybackReportUseExpectedRequests() async throws {
        let client = try makeClient()
        var requests: [URLRequest] = []
        JellyfinFeatureURLProtocol.handler = { request in
            requests.append(request)
            return (204, Data())
        }

        try await client.addToPlaylist(
            playlistID: "target",
            itemIDs: ["album", "artist", "source-playlist"],
            userID: "user",
            position: 3
        )
        try await client.setRating(itemID: "song", userID: "user", liked: true)
        try await client.reportPlaybackProgress(
            itemID: "song",
            positionTicks: 42,
            playSessionID: "session",
            isPaused: true,
            volumeLevel: 75,
            repeatMode: .repeatAll
        )

        #expect(requests.count == 3)
        #expect(requests[0].url?.path == "/jellyfin/Playlists/target/Items")
        #expect(requests[0].url?.query?.contains("Ids=album,artist,source-playlist") == true)
        #expect(requests[0].url?.query?.contains("position=3") == true)
        #expect(requests[1].url?.path == "/jellyfin/Users/user/Items/song/Rating")
        #expect(requests[1].url?.query?.contains("Likes=true") == true)
        #expect(requests[2].url?.path == "/jellyfin/Sessions/Playing/Progress")
        let body = try #require(requestBodyData(of: requests[2]))
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["PositionTicks"] as? Int == 42)
        #expect(json["IsPaused"] as? Bool == true)
        #expect(json["RepeatMode"] as? String == "RepeatAll")
    }

    // MARK: - PlaybackInfo constraints (Jellyfin Automatic)

    @Test func playbackInfoCarriesStreamingConstraints() async throws {
        let client = try makeClient()
        var requests: [URLRequest] = []
        JellyfinFeatureURLProtocol.handler = { request in
            requests.append(request)
            let payload = #"{"MediaSources":[{"Id":"ms1","Container":"alac","SupportsDirectPlay":true,"SupportsDirectStream":true,"SupportsTranscoding":true,"TranscodingContainer":"aac","Bitrate":900000,"MediaStreams":[{"Type":"Audio","Codec":"alac","Channels":2,"SampleRate":44100,"BitDepth":16,"BitRate":900000,"IsDefault":true}]}],"PlaySessionId":"ps1"}"#
            return (200, Data(payload.utf8))
        }

        let profile = JellyfinPlaybackInfoRequest.DeviceProfile(
            Name: "Cassette",
            MaxStreamingBitrate: 256_000,
            DirectPlayProfiles: [
                .init(Container: "alac", AudioCodec: "alac"),
                .init(Container: "flac", AudioCodec: "flac"),
            ],
            TranscodingProfiles: [
                .init(Container: "aac", AudioCodec: "aac", transport: "http", Context: "Streaming", MaxAudioChannels: "2")
            ]
        )
        let info = try await client.playbackInfo(
            itemID: "song",
            userID: "user",
            request: JellyfinPlaybackInfoRequest(MaxStreamingBitrate: 256_000, DeviceProfile: profile)
        )

        let request = try #require(requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/jellyfin/Items/song/PlaybackInfo")
        #expect(request.url?.query?.contains("UserId=user") == true)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

        let body = try #require(requestBodyData(of: request))
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        // The bitrate ceiling is what stops a 1 Mbps link being handed a lossless original.
        #expect(json["MaxStreamingBitrate"] as? Int == 256_000)
        #expect(json["UserId"] as? String == "user")
        #expect(json["AutoOpenLiveStream"] as? Bool == false)

        let profileJSON = try #require(json["DeviceProfile"] as? [String: Any])
        #expect(profileJSON["Name"] as? String == "Cassette")
        #expect(profileJSON["MaxStreamingBitrate"] as? Int == 256_000)
        let directProfiles = try #require(profileJSON["DirectPlayProfiles"] as? [[String: Any]])
        #expect(directProfiles.count == 2)
        // Swift reserves `Type`/`Protocol` as member names, so the wire keys are mapped explicitly.
        #expect(directProfiles.first?["Type"] as? String == "Audio")
        let transcodingProfiles = try #require(profileJSON["TranscodingProfiles"] as? [[String: Any]])
        #expect(transcodingProfiles.count == 1)
        #expect(transcodingProfiles.first?["Type"] as? String == "Audio")
        #expect(transcodingProfiles.first?["Protocol"] as? String == "http")

        // Stream detail needed by the client-side decision must survive decoding.
        let source = try #require(info.mediaSources.first)
        #expect(source.id == "ms1")
        #expect(source.bitrate == 900_000)
        #expect(source.transcodingContainer == "aac")
        #expect(source.mediaStreams?.first?.codec == "alac")
        #expect(source.mediaStreams?.first?.channels == 2)
        #expect(source.mediaStreams?.first?.bitDepth == 16)
        #expect(source.mediaStreams?.first?.isDefault == true)
        #expect(info.playSessionId == "ps1")
    }

    @Test func playbackInfoDecodesPartialCompatibilityPayload() async throws {
        // Navidrome's Jellyfin layer is experimental: it may answer with only the fields it knows.
        // Missing stream detail must decode without throwing and leave the optional fields nil.
        let client = try makeClient()
        JellyfinFeatureURLProtocol.handler = { _ in
            (200, Data(#"{"MediaSources":[{"Id":"ms1","SupportsDirectPlay":true}]}"#.utf8))
        }

        let info = try await client.playbackInfo(itemID: "song")
        let source = try #require(info.mediaSources.first)
        #expect(source.id == "ms1")
        #expect(source.supportsDirectPlay == true)
        #expect(source.bitrate == nil)
        #expect(source.mediaStreams == nil)
        #expect(source.transcodingContainer == nil)
        #expect(source.supportsTranscoding == nil)
        #expect(info.playSessionId == nil)
    }

    @Test func playbackInfoWithoutConstraintsKeepsEmptyBody() async throws {
        // The legacy overload must keep behaving exactly as before (no body at all).
        let client = try makeClient()
        var requests: [URLRequest] = []
        JellyfinFeatureURLProtocol.handler = { request in
            requests.append(request)
            return (200, Data(#"{"MediaSources":[]}"#.utf8))
        }

        _ = try await client.playbackInfo(itemID: "song")

        let request = try #require(requests.first)
        #expect(request.httpMethod == "POST")
        #expect(requestBodyData(of: request) == nil)
    }
}
