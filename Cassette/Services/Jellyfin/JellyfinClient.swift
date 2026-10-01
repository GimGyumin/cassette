// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.

import Foundation

nonisolated enum JellyfinClientError: Error, Sendable, Equatable {
    case invalidBaseURL
    case unavailable(statusCode: Int)
    case authenticationRequired
    case malformedResponse
    case quickConnectDisabled
    case quickConnectTimedOut
    case missingAuthenticatedUser
}

nonisolated struct JellyfinPublicSystemInfo: Codable, Sendable, Equatable {
    let localAddress: String?
    let serverName: String?
    let version: String?
    let productName: String?
    let operatingSystem: String?
    let id: String?

    enum CodingKeys: String, CodingKey {
        case localAddress = "LocalAddress"
        case serverName = "ServerName"
        case version = "Version"
        case productName = "ProductName"
        case operatingSystem = "OperatingSystem"
        case id = "Id"
    }
}

nonisolated struct JellyfinAuthenticationResult: Codable, Sendable {
    let accessToken: String
    let serverId: String?
    let user: JellyfinUser?

    enum CodingKeys: String, CodingKey {
        case accessToken = "AccessToken"
        case serverId = "ServerId"
        case user = "User"
    }
}

nonisolated struct JellyfinUser: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let name: String?

    enum CodingKeys: String, CodingKey { case id = "Id"; case name = "Name" }
}

nonisolated struct JellyfinQuickConnectState: Codable, Sendable {
    let authenticated: Bool?
    let secret: String?
    let code: String?
    let deviceId: String?
    let deviceName: String?
    let appName: String?
    let appVersion: String?
    let dateAdded: String?

    enum CodingKeys: String, CodingKey {
        case authenticated = "Authenticated"
        case secret = "Secret"
        case code = "Code"
        case deviceId = "DeviceId"
        case deviceName = "DeviceName"
        case appName = "AppName"
        case appVersion = "AppVersion"
        case dateAdded = "DateAdded"
    }
}

nonisolated struct JellyfinItem: Codable, Sendable, Identifiable, Equatable {
    let id: String
    let name: String?
    let type: String?
    let album: String?
    let albumId: String?
    let albumArtist: String?
    let albumArtists: [JellyfinNameIDPair]?
    let artists: [String]?
    let artistItems: [JellyfinNameIDPair]?
    let genreItems: [JellyfinNameIDPair]?
    let studios: [JellyfinNameIDPair]?
    let runTimeTicks: Int64?
    let playlistItemId: String?
    let imageTags: [String: String]?
    let genres: [String]?
    let productionYear: Int?
    let indexNumber: Int?
    let parentIndexNumber: Int?
    let hasLyrics: Bool?
    let normalizationGain: Double?
    let albumNormalizationGain: Double?
    let userData: JellyfinUserItemData?
    let mediaSources: [JellyfinMediaSource]?
    let playlistInfo: JellyfinPlaylistInfo?
    var childCount: Int? = nil
    var recursiveItemCount: Int? = nil
    var overview: String? = nil
    var dateCreated: String? = nil

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case type = "Type"
        case album = "Album"
        case albumId = "AlbumId"
        case albumArtist = "AlbumArtist"
        case albumArtists = "AlbumArtists"
        case artists = "Artists"
        case artistItems = "ArtistItems"
        case genreItems = "GenreItems"
        case studios = "Studios"
        case runTimeTicks = "RunTimeTicks"
        case playlistItemId = "PlaylistItemId"
        case imageTags = "ImageTags"
        case genres = "Genres"
        case productionYear = "ProductionYear"
        case indexNumber = "IndexNumber"
        case parentIndexNumber = "ParentIndexNumber"
        case hasLyrics = "HasLyrics"
        case normalizationGain = "NormalizationGain"
        case albumNormalizationGain = "AlbumNormalizationGain"
        case userData = "UserData"
        case mediaSources = "MediaSources"
        case childCount = "ChildCount"
        case recursiveItemCount = "RecursiveItemCount"
        case overview = "Overview"
        case dateCreated = "DateCreated"
        case playlistInfo = "PlaylistInfo"
    }
}

nonisolated struct JellyfinPlaylistInfo: Codable, Sendable, Equatable {
    let openAccess: Bool?
    let shares: [JellyfinPlaylistUserPermission]?
    let itemIDs: [String]?

    enum CodingKeys: String, CodingKey {
        case openAccess = "OpenAccess"
        case shares = "Shares"
        case itemIDs = "ItemIds"
    }
}

nonisolated struct JellyfinPlaylistUserPermission: Codable, Sendable, Equatable {
    let userID: String?
    let canEdit: Bool?

    enum CodingKeys: String, CodingKey {
        case userID = "UserId"
        case canEdit = "CanEdit"
    }
}

nonisolated struct JellyfinUserItemData: Codable, Sendable, Equatable {
    let playbackPositionTicks: Int64?
    let playCount: Int?
    let isFavorite: Bool?
    let played: Bool?
    let likes: Bool?
    let rating: Double?

    enum CodingKeys: String, CodingKey {
        case playbackPositionTicks = "PlaybackPositionTicks"
        case playCount = "PlayCount"
        case isFavorite = "IsFavorite"
        case played = "Played"
        case likes = "Likes"
        case rating = "Rating"
    }
}

nonisolated enum JellyfinItemType: String, Sendable, Equatable {
    case audio = "Audio"
    case musicAlbum = "MusicAlbum"
    case musicArtist = "MusicArtist"
    case musicGenre = "MusicGenre"
    case playlist = "Playlist"
    case collectionFolder = "CollectionFolder"
}

nonisolated enum JellyfinItemFilter: String, Sendable, Equatable {
    case favorite = "IsFavorite"
    case favoriteOrLiked = "IsFavoriteOrLikes"
    case played = "IsPlayed"
    case unplayed = "IsUnplayed"
}

nonisolated enum JellyfinSortOrder: String, Sendable, Equatable {
    case ascending = "Ascending"
    case descending = "Descending"
}

/// Complete collection query used by Navidrome's Jellyfin browsing endpoint.
/// IDs must be the GUID-form values returned by that endpoint.
nonisolated struct JellyfinItemsQuery: Sendable, Equatable {
    var parentID: String?
    var recursive = true
    var includeItemTypes: [JellyfinItemType] = []
    var excludeItemTypes: [JellyfinItemType] = []
    var itemIDs: [String] = []
    var artistIDs: [String] = []
    var albumArtistIDs: [String] = []
    var albumIDs: [String] = []
    var genreIDs: [String] = []
    var searchTerm: String?
    var filters: [JellyfinItemFilter] = []
    var sortBy: [String] = []
    var sortOrder: JellyfinSortOrder?
    var startIndex: Int?
    var limit: Int?
    var fields: [String] = []
    /// Passes supported server-specific filters (for example year or record label)
    /// without forcing callers to wait for a client release when Navidrome adds one.
    var additionalParameters: [String: [String]] = [:]

    var queryItems: [URLQueryItem] {
        var query = [URLQueryItem(name: "Recursive", value: recursive ? "true" : "false")]
        append(parentID, named: "ParentId", to: &query)
        append(includeItemTypes.map(\.rawValue), named: "IncludeItemTypes", to: &query)
        append(excludeItemTypes.map(\.rawValue), named: "ExcludeItemTypes", to: &query)
        append(itemIDs, named: "Ids", to: &query)
        append(artistIDs, named: "ArtistIds", to: &query)
        append(albumArtistIDs, named: "AlbumArtistIds", to: &query)
        append(albumIDs, named: "AlbumIds", to: &query)
        append(genreIDs, named: "GenreIds", to: &query)
        append(searchTerm, named: "SearchTerm", to: &query)
        append(filters.map(\.rawValue), named: "Filters", to: &query)
        append(sortBy, named: "SortBy", to: &query)
        append(sortOrder?.rawValue, named: "SortOrder", to: &query)
        append(startIndex.map(String.init), named: "StartIndex", to: &query)
        append(limit.map(String.init), named: "Limit", to: &query)
        append(fields, named: "Fields", to: &query)
        for name in additionalParameters.keys.sorted() {
            append(additionalParameters[name] ?? [], named: name, to: &query)
        }
        return query
    }

    private func append(_ value: String?, named name: String, to query: inout [URLQueryItem]) {
        guard let value, !value.isEmpty else { return }
        query.append(URLQueryItem(name: name, value: value))
    }

    private func append(_ values: [String], named name: String, to query: inout [URLQueryItem]) {
        guard !values.isEmpty else { return }
        query.append(URLQueryItem(name: name, value: values.joined(separator: ",")))
    }
}

nonisolated struct JellyfinNameIDPair: Codable, Sendable, Equatable {
    let name: String?
    let id: String?

    enum CodingKeys: String, CodingKey { case name = "Name"; case id = "Id" }
}

nonisolated struct JellyfinItemsResponse: Codable, Sendable, Equatable {
    let items: [JellyfinItem]
    let totalRecordCount: Int?

    enum CodingKeys: String, CodingKey {
        case items = "Items"
        case totalRecordCount = "TotalRecordCount"
    }
}

nonisolated struct JellyfinMediaStream: Codable, Sendable, Equatable {
    let type: String?
    let codec: String?
    let channels: Int?
    let sampleRate: Int?
    let bitDepth: Int?
    let bitRate: Int?
    let isDefault: Bool?

    enum CodingKeys: String, CodingKey {
        case type = "Type"
        case codec = "Codec"
        case channels = "Channels"
        case sampleRate = "SampleRate"
        case bitDepth = "BitDepth"
        case bitRate = "BitRate"
        case isDefault = "IsDefault"
    }
}

nonisolated struct JellyfinMediaSource: Codable, Sendable, Equatable {
    let id: String?
    let name: String?
    let path: String?
    let container: String?
    let supportsDirectPlay: Bool?
    let supportsDirectStream: Bool?
    let supportsTranscoding: Bool?
    let transcodingURL: String?
    /// Container the server would produce when transcoding (for example `aac` or `mp3`).
    let transcodingContainer: String?
    /// `hls` means the transcode is segmented; anything else is a progressive stream.
    let transcodingSubProtocol: String?
    /// Jellyfin reports the audio codec, channel count, sample rate and bit depth per stream, not on
    /// the source. Navidrome's compatibility layer fills in only the fields it knows, so the array
    /// (and every field in it) is optional and must never be required for a decision.
    let mediaStreams: [JellyfinMediaStream]?
    let bitrate: Int?
    let containerSize: Int64?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case path = "Path"
        case container = "Container"
        case supportsDirectPlay = "SupportsDirectPlay"
        case supportsDirectStream = "SupportsDirectStream"
        case supportsTranscoding = "SupportsTranscoding"
        case transcodingURL = "TranscodingUrl"
        case transcodingContainer = "TranscodingContainer"
        case transcodingSubProtocol = "TranscodingSubProtocol"
        case mediaStreams = "MediaStreams"
        case bitrate = "Bitrate"
        case containerSize = "Size"
    }
}

/// Body for `POST /Items/{id}/PlaybackInfo`.
///
/// This is what tells the server *what this device and this connection can take*: Jellyfin's whole
/// Direct Play vs Transcoding decision is meant to be driven by it. Sending an empty body (what the
/// app used to do) makes the server answer "Direct Play is fine" for a lossless original even on a
/// 1 Mbps cellular link, so the constraints have to travel with the request.
///
/// Navidrome's Jellyfin compatibility layer is experimental and may ignore parts of it, which is why
/// the client still makes the final decision (`PlaybackDecisionPolicy`).
nonisolated struct JellyfinPlaybackInfoRequest: Encodable, Sendable, Equatable {

    nonisolated struct DeviceProfile: Encodable, Sendable, Equatable {
        nonisolated struct DirectPlayProfile: Encodable, Sendable, Equatable {
            let Container: String
            var AudioCodec: String?
            /// Jellyfin calls this `Type`. Swift reserves `Type` as a member name, so it is mapped.
            var mediaType: String = "Audio"

            enum CodingKeys: String, CodingKey {
                case Container, AudioCodec
                case mediaType = "Type"
            }
        }

        nonisolated struct TranscodingProfile: Encodable, Sendable, Equatable {
            let Container: String
            var mediaType: String = "Audio"
            var AudioCodec: String?
            /// Jellyfin calls this `Protocol`; Swift reserves that name too.
            var transport: String?
            var Context: String?
            var MaxAudioChannels: String?

            enum CodingKeys: String, CodingKey {
                case Container, AudioCodec, Context, MaxAudioChannels
                case mediaType = "Type"
                case transport = "Protocol"
            }
        }

        let Name: String
        var MaxStreamingBitrate: Int?
        var DirectPlayProfiles: [DirectPlayProfile]
        var TranscodingProfiles: [TranscodingProfile]
    }

    var UserId: String?
    /// Bits per second. Jellyfin expects bit/s here, not the kbps Subsonic uses.
    var MaxStreamingBitrate: Int?
    var DeviceProfile: DeviceProfile?
    var AutoOpenLiveStream: Bool = false
}

nonisolated struct JellyfinPlaybackInfo: Codable, Sendable, Equatable {
    let mediaSources: [JellyfinMediaSource]
    let playSessionId: String?

    enum CodingKeys: String, CodingKey {
        case mediaSources = "MediaSources"
        case playSessionId = "PlaySessionId"
    }
}

nonisolated struct JellyfinLyricLine: Codable, Sendable, Equatable {
    let text: String?
    let start: Int64?
    let cues: [JellyfinLyricCue]?

    enum CodingKeys: String, CodingKey {
        case text = "Text"
        case start = "Start"
        case cues = "Cues"
    }
}

nonisolated struct JellyfinLyricCue: Codable, Sendable, Equatable {
    /// Text offsets into the parent line's `Text` value.
    let position: Int?
    let endPosition: Int?
    let start: Int64?
    let end: Int64?

    enum CodingKeys: String, CodingKey {
        case position = "Position"
        case endPosition = "EndPosition"
        case start = "Start"
        case end = "End"
    }
}

nonisolated struct JellyfinLyricMetadata: Codable, Sendable, Equatable {
    let artist: String?
    let album: String?
    let title: String?
    let length: Int64?
    let offset: Int64?
    let isSynced: Bool?

    enum CodingKeys: String, CodingKey {
        case artist = "Artist"
        case album = "Album"
        case title = "Title"
        case length = "Length"
        case offset = "Offset"
        case isSynced = "IsSynced"
    }
}

nonisolated struct JellyfinLyricsResult: Codable, Sendable, Equatable {
    let metadata: JellyfinLyricMetadata?
    let lyrics: [JellyfinLyricLine]?
    let text: String?
    let synced: Bool?

    enum CodingKeys: String, CodingKey {
        case metadata = "Metadata"
        case lyrics = "Lyrics"
        case text = "Text"
        case synced = "IsSynced"
    }
}

nonisolated struct JellyfinAudioMuseInfo: Codable, Sendable, Equatable {
    let version: String?
    let availableEndpoints: [String]?

    enum CodingKeys: String, CodingKey {
        case version = "Version"
        case availableEndpoints = "AvailableEndpoints"
    }
}

nonisolated enum JellyfinInstantMixSource: String, Sendable {
    case item = "Items"
    case song = "Songs"
    case album = "Albums"
    case artist = "Artists"
    case playlist = "Playlists"
    case genre = "MusicGenres"
}

nonisolated enum JellyfinPlayMethod: String, Sendable {
    case directPlay = "DirectPlay"
    case directStream = "DirectStream"
    case transcode = "Transcode"
}

nonisolated enum JellyfinRepeatMode: String, Sendable {
    case repeatNone = "RepeatNone"
    case repeatAll = "RepeatAll"
    case repeatOne = "RepeatOne"
}

/// A small, testable Jellyfin HTTP boundary. It never derives a Jellyfin GUID from another ID.
/// Callers must pass IDs exactly as returned by the server.
nonisolated final class JellyfinClient: @unchecked Sendable {
    let baseURL: URL
    private let accessToken: String?
    private let customHeaders: [String: String]
    private let session: URLSession
    private let deviceID: String
    private let deviceName: String
    private let clientName: String
    private let clientVersion: String

    init(
        serverBaseURL: URL,
        accessToken: String? = nil,
        customHeaders: [String: String] = [:],
        deviceID: String,
        deviceName: String = "Apple Device",
        clientName: String = "Cassette",
        clientVersion: String = "1",
        session: URLSession = .shared
    ) throws {
        guard let baseURL = Self.jellyfinBaseURL(from: serverBaseURL) else {
            throw JellyfinClientError.invalidBaseURL
        }
        self.baseURL = baseURL
        self.accessToken = accessToken
        self.customHeaders = customHeaders
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.clientName = clientName
        self.clientVersion = clientVersion
        self.session = session
    }

    static func jellyfinBaseURL(from serverBaseURL: URL) -> URL? {
        guard var components = URLComponents(url: serverBaseURL, resolvingAgainstBaseURL: false),
              components.scheme != nil, components.host != nil else { return nil }
        var path = components.path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        if path == "/" { path = "" }
        if !path.lowercased().hasSuffix("/jellyfin") {
            path += "/jellyfin"
        }
        components.path = path
        components.query = nil
        components.fragment = nil
        return components.url
    }

    func publicSystemInfo() async throws -> JellyfinPublicSystemInfo {
        try await request("System/Info/Public", authenticated: false)
    }

    func authenticate(username: String, password: String) async throws -> JellyfinAuthenticationResult {
        struct Body: Encodable { let Username: String; let Pw: String }
        return try await request("Users/AuthenticateByName", method: "POST", body: Body(Username: username, Pw: password), authenticated: false)
    }

    func publicUsers() async throws -> [JellyfinUser] {
        try await request("Users/Public", authenticated: false)
    }

    func quickConnectEnabled() async throws -> Bool {
        let response: Bool = try await request("QuickConnect/Enabled", authenticated: false)
        return response
    }

    func initiateQuickConnect() async throws -> JellyfinQuickConnectState {
        try await request("QuickConnect/Initiate", method: "POST", authenticated: false)
    }

    func quickConnectState(secret: String) async throws -> JellyfinQuickConnectState {
        try await request("QuickConnect/Connect", query: [URLQueryItem(name: "Secret", value: secret)], authenticated: false)
    }

    func authenticateQuickConnect(secret: String) async throws -> JellyfinAuthenticationResult {
        struct Body: Encodable { let Secret: String }
        return try await request("Users/AuthenticateWithQuickConnect", method: "POST", body: Body(Secret: secret), authenticated: false)
    }

    func authorizeQuickConnect(code: String, userID: String? = nil) async throws {
        var query = [URLQueryItem(name: "Code", value: code)]
        if let userID { query.append(URLQueryItem(name: "UserId", value: userID)) }
        try await requestWithoutResponse("QuickConnect/Authorize", method: "POST", query: query, body: EmptyBody())
    }

    func currentUser() async throws -> JellyfinUser {
        try await request("Users/Me")
    }

    func userViews() async throws -> JellyfinItemsResponse {
        try await request("UserViews")
    }

    func item(itemID: String, userID: String? = nil) async throws -> JellyfinItem {
        let path = userID.map { "Users/\($0)/Items/\(itemID)" } ?? "Items/\(itemID)"
        return try await request(path)
    }

    func items(userID: String? = nil, query: JellyfinItemsQuery = JellyfinItemsQuery()) async throws -> JellyfinItemsResponse {
        let path = userID.map { "Users/\($0)/Items" } ?? "Items"
        return try await request(path, query: query.queryItems)
    }

    func items(
        userID: String,
        parentID: String? = nil,
        includeItemTypes: [String] = [],
        startIndex: Int? = nil,
        limit: Int? = nil
    ) async throws -> JellyfinItemsResponse {
        var query = JellyfinItemsQuery()
        query.parentID = parentID
        query.includeItemTypes = includeItemTypes.compactMap(JellyfinItemType.init(rawValue:))
        query.startIndex = startIndex
        query.limit = limit
        return try await items(userID: userID, query: query)
    }

    func latestItems(userID: String, parentID: String? = nil, limit: Int? = nil) async throws -> [JellyfinItem] {
        var query: [URLQueryItem] = []
        if let parentID { query.append(URLQueryItem(name: "ParentId", value: parentID)) }
        if let limit { query.append(URLQueryItem(name: "Limit", value: String(limit))) }
        return try await request("Users/\(userID)/Items/Latest", query: query)
    }

    func artists(albumArtistsOnly: Bool = false, query: JellyfinItemsQuery = JellyfinItemsQuery()) async throws -> JellyfinItemsResponse {
        try await request(albumArtistsOnly ? "Artists/AlbumArtists" : "Artists", query: query.queryItems)
    }

    func genres(musicOnly: Bool = true, query: JellyfinItemsQuery = JellyfinItemsQuery()) async throws -> JellyfinItemsResponse {
        try await request(musicOnly ? "MusicGenres" : "Genres", query: query.queryItems)
    }

    /// Playback info with no client constraints — the legacy empty-body request.
    func playbackInfo(itemID: String, userID: String? = nil) async throws -> JellyfinPlaybackInfo {
        var query: [URLQueryItem] = []
        if let userID { query.append(URLQueryItem(name: "UserId", value: userID)) }
        return try await request(
            "Items/\(itemID)/PlaybackInfo",
            method: "POST",
            query: query,
            body: Optional<EmptyBody>.none
        )
    }

    /// `POST /Items/{id}/PlaybackInfo` carrying this device's decoding capability and the current
    /// connection's bitrate ceiling, so the server answers Direct Play vs Transcoding for *this* link
    /// instead of for a hypothetical fast one.
    func playbackInfo(
        itemID: String,
        userID: String? = nil,
        request constraints: JellyfinPlaybackInfoRequest
    ) async throws -> JellyfinPlaybackInfo {
        var query: [URLQueryItem] = []
        if let userID { query.append(URLQueryItem(name: "UserId", value: userID)) }
        var body = constraints
        if body.UserId == nil { body.UserId = userID }
        return try await request("Items/\(itemID)/PlaybackInfo", method: "POST", query: query, body: body)
    }

    func lyrics(itemID: String) async throws -> JellyfinLyricsResult {
        try await request("Audio/\(itemID)/Lyrics")
    }

    func instantMix(
        itemID: String,
        source: JellyfinInstantMixSource = .item,
        userID: String? = nil,
        limit: Int = 50
    ) async throws -> JellyfinItemsResponse {
        var query = [URLQueryItem(name: "Limit", value: String(limit))]
        if let userID { query.append(URLQueryItem(name: "UserId", value: userID)) }
        if source == .genre {
            query.append(URLQueryItem(name: "id", value: itemID))
            return try await request("MusicGenres/InstantMix", query: query)
        }
        return try await request("\(source.rawValue)/\(itemID)/InstantMix", query: query)
    }

    func similarItems(itemID: String, userID: String? = nil, limit: Int = 50) async throws -> JellyfinItemsResponse {
        var query = [URLQueryItem(name: "Limit", value: String(limit))]
        if let userID { query.append(URLQueryItem(name: "UserId", value: userID)) }
        return try await request("Items/\(itemID)/Similar", query: query)
    }

    func createPlaylist(name: String, userID: String, itemIDs: [String] = [], isPublic: Bool = false) async throws -> JellyfinItem {
        struct Body: Encodable {
            let Name: String
            let UserId: String
            let Ids: [String]
            let IsPublic: Bool
        }
        return try await request("Playlists", method: "POST", body: Body(Name: name, UserId: userID, Ids: itemIDs, IsPublic: isPublic))
    }

    func playlistItems(playlistID: String, userID: String? = nil, startIndex: Int? = nil, limit: Int? = nil) async throws -> JellyfinItemsResponse {
        var query: [URLQueryItem] = []
        if let startIndex { query.append(URLQueryItem(name: "StartIndex", value: String(startIndex))) }
        if let limit { query.append(URLQueryItem(name: "Limit", value: String(limit))) }
        if let userID { query.append(URLQueryItem(name: "UserId", value: userID)) }
        return try await request("Playlists/\(playlistID)/Items", query: query)
    }

    func playlist(playlistID: String) async throws -> JellyfinPlaylistInfo {
        try await request("Playlists/\(playlistID)")
    }

    func playlistUsers(playlistID: String) async throws -> [JellyfinPlaylistUserPermission] {
        try await request("Playlists/\(playlistID)/Users")
    }

    func playlistUser(playlistID: String, userID: String) async throws -> JellyfinPlaylistUserPermission {
        try await request("Playlists/\(playlistID)/Users/\(userID)")
    }

    func updatePlaylist(playlistID: String, name: String, isPublic: Bool) async throws {
        try await updatePlaylist(playlistID: playlistID, name: Optional(name), isPublic: Optional(isPublic))
    }

    /// Updates only the supplied fields. Supplying `itemIDs: []` explicitly clears the playlist.
    func updatePlaylist(
        playlistID: String,
        name: String? = nil,
        isPublic: Bool? = nil,
        itemIDs: [String]? = nil
    ) async throws {
        struct Body: Encodable {
            let Name: String?
            let IsPublic: Bool?
            let Ids: [String]?
        }
        try await requestWithoutResponse(
            "Playlists/\(playlistID)",
            method: "POST",
            body: Body(Name: name, IsPublic: isPublic, Ids: itemIDs)
        )
    }

    func replacePlaylistItems(playlistID: String, itemIDs: [String]) async throws {
        try await updatePlaylist(playlistID: playlistID, itemIDs: itemIDs)
    }

    func deletePlaylist(playlistID: String) async throws {
        try await requestWithoutResponse("Items/\(playlistID)", method: "DELETE")
    }

    /// Navidrome expands album, artist and playlist container IDs into their tracks server-side.
    func addToPlaylist(
        playlistID: String,
        itemIDs: [String],
        userID: String? = nil,
        position: Int? = nil
    ) async throws {
        var query = [URLQueryItem(name: "Ids", value: itemIDs.joined(separator: ","))]
        if let userID { query.append(URLQueryItem(name: "UserId", value: userID)) }
        if let position { query.append(URLQueryItem(name: "position", value: String(position))) }
        try await requestWithoutResponse("Playlists/\(playlistID)/Items", method: "POST", query: query, body: EmptyBody())
    }

    /// `entryIDs` are PlaylistItemId occurrence IDs, not media item IDs. This preserves
    /// duplicate tracks and removes/reorders the exact occurrence selected by the user.
    func removeFromPlaylist(playlistID: String, entryIDs: [String]) async throws {
        let query = [URLQueryItem(name: "EntryIds", value: entryIDs.joined(separator: ","))]
        try await requestWithoutResponse("Playlists/\(playlistID)/Items", method: "DELETE", query: query)
    }

    func movePlaylistEntry(playlistID: String, playlistItemID: String, newIndex: Int) async throws {
        try await requestWithoutResponse("Playlists/\(playlistID)/Items/\(playlistItemID)/Move/\(newIndex)", method: "POST", body: EmptyBody())
    }

    func uploadPlaylistArtwork(playlistID: String, data: Data, mimeType: String) async throws {
        _ = try await performData(
            "Items/\(playlistID)/Images/Primary",
            method: "POST",
            contentType: mimeType,
            data: data,
            authenticated: true
        )
    }

    func deletePlaylistArtwork(playlistID: String) async throws {
        try await requestWithoutResponse("Items/\(playlistID)/Images/Primary", method: "DELETE")
    }

    func setFavorite(itemID: String, userID: String, favorite: Bool) async throws {
        let method = favorite ? "POST" : "DELETE"
        try await requestWithoutResponse("Users/\(userID)/FavoriteItems/\(itemID)", method: method)
    }

    func userData(itemID: String, userID: String? = nil) async throws -> JellyfinUserItemData {
        let path = userID.map { "Users/\($0)/Items/\(itemID)/UserData" } ?? "UserItems/\(itemID)/UserData"
        return try await request(path)
    }

    /// Jellyfin ratings are like/dislike values. Pass nil to clear the rating.
    func setRating(itemID: String, userID: String, liked: Bool?) async throws {
        let path = "Users/\(userID)/Items/\(itemID)/Rating"
        if let liked {
            try await requestWithoutResponse(
                path,
                method: "POST",
                query: [URLQueryItem(name: "Likes", value: liked ? "true" : "false")],
                body: EmptyBody()
            )
        } else {
            try await requestWithoutResponse(path, method: "DELETE")
        }
    }

    func audioMuseInfo() async throws -> JellyfinAudioMuseInfo {
        try await request("AudioMuseAI/info")
    }

    func reportPlaybackStarted(
        itemID: String,
        positionTicks: Int64 = 0,
        playSessionID: String? = nil,
        mediaSourceID: String? = nil,
        playMethod: JellyfinPlayMethod? = nil
    ) async throws {
        try await reportPlayback(path: "Sessions/Playing", itemID: itemID, positionTicks: positionTicks, playSessionID: playSessionID, mediaSourceID: mediaSourceID, playMethod: playMethod)
    }

    func reportPlaybackProgress(
        itemID: String,
        positionTicks: Int64,
        playSessionID: String? = nil,
        isPaused: Bool? = nil,
        isMuted: Bool? = nil,
        volumeLevel: Int? = nil,
        repeatMode: JellyfinRepeatMode? = nil
    ) async throws {
        try await reportPlayback(path: "Sessions/Playing/Progress", itemID: itemID, positionTicks: positionTicks, playSessionID: playSessionID, isPaused: isPaused, isMuted: isMuted, volumeLevel: volumeLevel, repeatMode: repeatMode)
    }

    func reportPlaybackStopped(itemID: String, positionTicks: Int64, playSessionID: String? = nil) async throws {
        try await reportPlayback(path: "Sessions/Playing/Stopped", itemID: itemID, positionTicks: positionTicks, playSessionID: playSessionID)
    }

    func directStreamURL(
        itemID: String,
        container: String? = nil,
        mediaSourceID: String? = nil,
        playSessionID: String? = nil
    ) -> URL? {
        var query = [URLQueryItem(name: "DeviceId", value: deviceID)]
        if let mediaSourceID { query.append(URLQueryItem(name: "MediaSourceId", value: mediaSourceID)) }
        if let playSessionID { query.append(URLQueryItem(name: "PlaySessionId", value: playSessionID)) }
        return authenticatedURL("Audio/\(itemID)/stream\(container.map { ".\($0)" } ?? "")", query: query)
    }

    func universalAudioURL(
        itemID: String,
        container: String? = nil,
        audioCodec: String? = nil,
        maxStreamingBitrate: Int? = nil,
        mediaSourceID: String? = nil,
        playSessionID: String? = nil,
        staticStream: Bool = true
    ) -> URL? {
        var query = [
            URLQueryItem(name: "Static", value: staticStream ? "true" : "false"),
            URLQueryItem(name: "DeviceId", value: deviceID),
        ]
        if let container { query.append(URLQueryItem(name: "Container", value: container)) }
        if let audioCodec { query.append(URLQueryItem(name: "AudioCodec", value: audioCodec)) }
        if let maxStreamingBitrate { query.append(URLQueryItem(name: "MaxStreamingBitrate", value: String(maxStreamingBitrate))) }
        if let mediaSourceID { query.append(URLQueryItem(name: "MediaSourceId", value: mediaSourceID)) }
        if let playSessionID { query.append(URLQueryItem(name: "PlaySessionId", value: playSessionID)) }
        return authenticatedURL("Audio/\(itemID)/universal", query: query)
    }

    func hlsURL(
        itemID: String,
        audioCodec: String? = nil,
        maxStreamingBitrate: Int? = nil,
        mediaSourceID: String? = nil,
        playSessionID: String? = nil
    ) -> URL? {
        var query = [URLQueryItem(name: "DeviceId", value: deviceID)]
        if let audioCodec { query.append(URLQueryItem(name: "AudioCodec", value: audioCodec)) }
        if let maxStreamingBitrate { query.append(URLQueryItem(name: "MaxStreamingBitrate", value: String(maxStreamingBitrate))) }
        if let mediaSourceID { query.append(URLQueryItem(name: "MediaSourceId", value: mediaSourceID)) }
        if let playSessionID { query.append(URLQueryItem(name: "PlaySessionId", value: playSessionID)) }
        return authenticatedURL("Audio/\(itemID)/main.m3u8", query: query)
    }

    func originalFileURL(itemID: String, mediaSourceID: String? = nil, playSessionID: String? = nil) -> URL? {
        var query = [URLQueryItem(name: "DeviceId", value: deviceID)]
        if let mediaSourceID { query.append(URLQueryItem(name: "MediaSourceId", value: mediaSourceID)) }
        if let playSessionID { query.append(URLQueryItem(name: "PlaySessionId", value: playSessionID)) }
        return authenticatedURL("Items/\(itemID)/File", query: query)
    }

    func downloadURL(itemID: String) -> URL? {
        authenticatedURL("Items/\(itemID)/Download")
    }

    func artworkURL(itemID: String, type: String = "Primary", index: Int? = nil, maxWidth: Int? = nil) -> URL? {
        var path = "Items/\(itemID)/Images/\(type)"
        if let index { path += "/\(index)" }
        var query: [URLQueryItem] = []
        if let maxWidth { query.append(URLQueryItem(name: "MaxWidth", value: String(maxWidth))) }
        return authenticatedURL(path, query: query)
    }

    /// Compatibility alias retained for existing call sites.
    func audioURL(itemID: String, container: String? = nil, staticStream: Bool = true) -> URL? {
        universalAudioURL(itemID: itemID, container: container, staticStream: staticStream)
    }

    private struct EmptyBody: Encodable {}

    private func reportPlayback(
        path: String,
        itemID: String,
        positionTicks: Int64,
        playSessionID: String?,
        mediaSourceID: String? = nil,
        playMethod: JellyfinPlayMethod? = nil,
        isPaused: Bool? = nil,
        isMuted: Bool? = nil,
        volumeLevel: Int? = nil,
        repeatMode: JellyfinRepeatMode? = nil
    ) async throws {
        struct Body: Encodable {
            let ItemId: String
            let PositionTicks: Int64
            let PlaySessionId: String?
            let MediaSourceId: String?
            let PlayMethod: String?
            let IsPaused: Bool?
            let IsMuted: Bool?
            let VolumeLevel: Int?
            let RepeatMode: String?
        }
        try await requestWithoutResponse(
            path,
            method: "POST",
            body: Body(
                ItemId: itemID,
                PositionTicks: positionTicks,
                PlaySessionId: playSessionID,
                MediaSourceId: mediaSourceID,
                PlayMethod: playMethod?.rawValue,
                IsPaused: isPaused,
                IsMuted: isMuted,
                VolumeLevel: volumeLevel,
                RepeatMode: repeatMode?.rawValue
            )
        )
    }

    private func request<Response: Decodable>(
        _ path: String,
        method: String = "GET",
        query: [URLQueryItem] = [],
        authenticated: Bool = true
    ) async throws -> Response {
        try await request(path, method: method, query: query, body: Optional<EmptyBody>.none, authenticated: authenticated)
    }

    private func request<Response: Decodable, Body: Encodable>(
        _ path: String,
        method: String = "GET",
        query: [URLQueryItem] = [],
        body: Body?,
        authenticated: Bool = true
    ) async throws -> Response {
        let (data, _) = try await perform(path, method: method, query: query, body: body, authenticated: authenticated)
        guard !data.isEmpty else { throw JellyfinClientError.malformedResponse }
        do { return try JSONDecoder().decode(Response.self, from: data) }
        catch { throw JellyfinClientError.malformedResponse }
    }

    private func requestWithoutResponse<Body: Encodable>(
        _ path: String,
        method: String,
        query: [URLQueryItem] = [],
        body: Body? = Optional<EmptyBody>.none
    ) async throws {
        _ = try await perform(path, method: method, query: query, body: body, authenticated: true)
    }

    private func perform<Body: Encodable>(
        _ path: String,
        method: String,
        query: [URLQueryItem],
        body: Body?,
        authenticated: Bool
    ) async throws -> (Data, HTTPURLResponse) {
        if authenticated && accessToken == nil { throw JellyfinClientError.authenticationRequired }
        guard let url = endpoint(path, query: query) else { throw JellyfinClientError.invalidBaseURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        request.setValue(authorizationHeader, forHTTPHeaderField: "X-Emby-Authorization")
        if let accessToken { request.setValue(accessToken, forHTTPHeaderField: "X-Emby-Token") }
        for (name, value) in customHeaders { request.setValue(value, forHTTPHeaderField: name) }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw JellyfinClientError.malformedResponse }
        guard let finalURL = http.url,
              finalURL.path.lowercased().hasPrefix(baseURL.path.lowercased()) else {
            // Reverse proxies commonly redirect a disabled /jellyfin route to the web app.
            // Treat that as endpoint absence while leaving OpenSubsonic fully operational.
            throw JellyfinClientError.unavailable(statusCode: 404)
        }
        guard (200..<300).contains(http.statusCode) else { throw JellyfinClientError.unavailable(statusCode: http.statusCode) }
        return (data, http)
    }

    private func performData(
        _ path: String,
        method: String,
        query: [URLQueryItem] = [],
        contentType: String,
        data: Data,
        authenticated: Bool
    ) async throws -> (Data, HTTPURLResponse) {
        if authenticated && accessToken == nil { throw JellyfinClientError.authenticationRequired }
        guard let url = endpoint(path, query: query) else { throw JellyfinClientError.invalidBaseURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        request.setValue(authorizationHeader, forHTTPHeaderField: "X-Emby-Authorization")
        if let accessToken { request.setValue(accessToken, forHTTPHeaderField: "X-Emby-Token") }
        for (name, value) in customHeaders { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = data
        let (responseData, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw JellyfinClientError.malformedResponse }
        guard let finalURL = http.url,
              finalURL.path.lowercased().hasPrefix(baseURL.path.lowercased()) else {
            throw JellyfinClientError.unavailable(statusCode: 404)
        }
        guard (200..<300).contains(http.statusCode) else { throw JellyfinClientError.unavailable(statusCode: http.statusCode) }
        return (responseData, http)
    }

    private func endpoint(_ path: String, query: [URLQueryItem]) -> URL? {
        var url = baseURL
        for component in path.split(separator: "/") { url.appendPathComponent(String(component)) }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        if !query.isEmpty { components.queryItems = query }
        return components.url
    }

    private func authenticatedURL(_ path: String, query: [URLQueryItem] = []) -> URL? {
        var query = query
        if let accessToken { query.append(URLQueryItem(name: "api_key", value: accessToken)) }
        return endpoint(path, query: query)
    }

    private var authorizationHeader: String {
        let fields = [
            ("Client", clientName),
            ("Device", deviceName),
            ("DeviceId", deviceID),
            ("Version", clientVersion),
        ]
        return "MediaBrowser " + fields.map { name, value in
            let sanitized = value
                .replacingOccurrences(of: "\\", with: "_")
                .replacingOccurrences(of: "\"", with: "_")
                .replacingOccurrences(of: "\r", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
            return "\(name)=\"\(sanitized)\""
        }.joined(separator: ", ")
    }
}
