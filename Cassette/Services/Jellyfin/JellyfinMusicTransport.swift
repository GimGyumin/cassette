// Cassette — Licensed under the Mozilla Public License 2.0.
import Foundation
import SwiftSonic

/// Keeps the app's existing music models while routing every request through Jellyfin.
/// The Subsonic-shaped response exists only in memory; no /rest/ request is sent.
nonisolated final class JellyfinMusicTransport: HTTPTransport, Sendable {
    let client: JellyfinClient
    let user: JellyfinUser

    init(client: JellyfinClient, user: JellyfinUser) {
        self.client = client
        self.user = user
    }

    func makeMusicClient(serverURL: URL) -> SwiftSonicClient {
        SwiftSonicClient(
            configuration: ServerConfiguration(
                serverURL: serverURL,
                auth: .apiKey("local-jellyfin-adapter"),
                clientName: "Cassette",
                mediaURLResolver: { [self] in mediaURL(endpoint: $0, parameters: $1) }
            ),
            transport: self,
            retryPolicy: .none
        )
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        guard let url = request.url else { throw JellyfinClientError.invalidBaseURL }
        let endpoint = url.deletingPathExtension().lastPathComponent
        let pairs = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let parameters = Dictionary(grouping: pairs, by: \.name).mapValues { $0.compactMap(\.value) }
        var response: [String: Any] = ["status": "ok", "version": "1.16.1",
                                       "openSubsonic": true, "type": "CassetteJellyfinAdapter"]
        do {
            response.merge(try await payload(endpoint, parameters)) { _, new in new }
        } catch AdapterError.unsupported {
            response = ["status": "failed", "version": "1.16.1",
                        "error": ["code": 0, "message": "This operation is not available through Jellyfin."]]
        }
        let data = try JSONSerialization.data(withJSONObject: ["subsonic-response": response])
        return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                     headerFields: ["Content-Type": "application/json"])!)
    }

    private func payload(_ endpoint: String, _ p: [String: [String]]) async throws -> [String: Any] {
        @Sendable func value(_ key: String) -> String? { p[key]?.first }
        @Sendable func count(_ key: String, _ fallback: Int) -> Int { max(0, value(key).flatMap(Int.init) ?? fallback) }
        let id = Self.remoteID(value("id") ?? value("playlistId") ?? "")
        switch endpoint {
        case "ping":
            _ = try await client.currentUser()
            return [:]
        case "getOpenSubsonicExtensions":
            return ["openSubsonicExtensions": [["name": "songLyrics", "versions": [1]]]]
        case "getUser":
            let current = try await client.currentUser()
            return ["user": ["username": current.name ?? ""]]
        case "search3":
            let term = value("query") ?? ""
            async let artists = collection(.musicArtist, search: term, offset: count("artistOffset", 0), limit: count("artistCount", 20))
            async let albums = collection(.musicAlbum, search: term, offset: count("albumOffset", 0), limit: count("albumCount", 20))
            async let songs = collection(.audio, search: term, offset: count("songOffset", 0), limit: count("songCount", 20))
            return try await ["searchResult3": ["artist": artists.map(Self.artist), "album": albums.map(Self.album), "song": songs.map(Self.song)]]
        case "getAlbumList2":
            var query = baseQuery(.musicAlbum)
            query.startIndex = count("offset", 0)
            query.limit = count("size", 10)
            let sorts = ["newest": "DateCreated", "recent": "DatePlayed", "frequent": "PlayCount",
                         "alphabeticalByName": "SortName", "alphabeticalByArtist": "AlbumArtist", "random": "Random", "byYear": "ProductionYear"]
            let type = value("type") ?? "newest"
            query.sortBy = [sorts[type] ?? "SortName"]
            query.sortOrder = ["newest", "recent", "frequent"].contains(type) ? .descending : .ascending
            if type == "starred" { query.filters = [.favorite] }
            if type == "recent" || type == "frequent" { query.filters = [.played] }
            if let genre = value("genre") {
                guard let genreID = try await genreID(named: genre) else { return ["albumList2": ["album": []]] }
                query.genreIDs = [genreID]
            }
            if let from = value("fromYear"), let to = value("toYear"), let a = Int(from), let b = Int(to) {
                query.additionalParameters["Years"] = (min(a, b)...max(a, b)).prefix(10000).map(String.init)
                query.sortOrder = a <= b ? .ascending : .descending
            }
            return ["albumList2": ["album": try await page(query).map(Self.album)]]
        case "getArtists":
            let artists = try await all(baseQuery(.musicArtist))
            return ["artists": ["index": [["name": "", "artist": artists.map(Self.artist)]]]]
        case "getArtist":
            let item = try await client.item(itemID: id, userID: user.id)
            var query = baseQuery(.musicAlbum)
            query.albumArtistIDs = [id]
            var result = Self.artist(item)
            result["album"] = try await all(query).map(Self.album)
            return ["artist": result]
        case "getAlbum":
            let item = try await client.item(itemID: id, userID: user.id)
            var query = baseQuery(.audio)
            query.parentID = id
            query.sortBy = ["ParentIndexNumber", "IndexNumber", "SortName"]
            let songs = try await all(query)
            var result = Self.album(item)
            result["song"] = songs.map(Self.song)
            result["songCount"] = songs.count
            result["duration"] = songs.reduce(0) { $0 + Self.seconds($1) }
            return ["album": result]
        case "getSong":
            return ["song": Self.song(try await client.item(itemID: id, userID: user.id))]
        case "getAlbumInfo2", "getArtistInfo2":
            let item = try await client.item(itemID: id, userID: user.id)
            return [endpoint == "getAlbumInfo2" ? "albumInfo" : "artistInfo2":
                        [endpoint == "getAlbumInfo2" ? "notes" : "biography": item.overview ?? ""]]
        case "getPlaylists":
            return ["playlists": ["playlist": try await all(baseQuery(.playlist)).map(Self.playlist)]]
        case "getPlaylist":
            return ["playlist": try await playlistDetail(id)]
        case "createPlaylist":
            let ids = (p["songId"] ?? []).map(Self.remoteID)
            let playlistID: String
            if let existing = value("playlistId") {
                playlistID = Self.remoteID(existing)
                try await client.replacePlaylistItems(playlistID: playlistID, itemIDs: ids)
            } else {
                playlistID = try await client.createPlaylist(name: value("name") ?? "", userID: user.id, itemIDs: ids).id
            }
            return ["playlist": try await playlistDetail(playlistID)]
        case "updatePlaylist":
            // Descriptions have no equivalent in the supported Jellyfin playlist API.
            if value("comment") != nil { throw AdapterError.unsupported }
            let remove = (p["songIndexToRemove"] ?? []).compactMap(Int.init)
            if !remove.isEmpty {
                let entries = try await playlistEntries(id)
                let ids = try remove.map { index -> String in
                    guard entries.indices.contains(index), let entry = entries[index].playlistItemId else {
                        throw JellyfinClientError.malformedResponse
                    }
                    return entry
                }
                try await client.removeFromPlaylist(playlistID: id, entryIDs: ids)
            }
            let additions = (p["songIdToAdd"] ?? []).map(Self.remoteID)
            if !additions.isEmpty { try await client.addToPlaylist(playlistID: id, itemIDs: additions, userID: user.id) }
            if value("name") != nil || value("public") != nil {
                try await client.updatePlaylist(playlistID: id, name: value("name"), isPublic: value("public").map { $0 == "true" })
            }
            return [:]
        case "deletePlaylist":
            try await client.deletePlaylist(playlistID: id)
            return [:]
        case "star", "unstar":
            for itemID in ["id", "albumId", "artistId"].flatMap({ p[$0] ?? [] }) {
                try await client.setFavorite(itemID: Self.remoteID(itemID), userID: user.id, favorite: endpoint == "star")
            }
            return [:]
        case "getStarred2":
            var query = baseQuery(.audio)
            query.includeItemTypes = [.audio, .musicAlbum, .musicArtist]
            query.filters = [.favorite]
            let items = try await all(query)
            return ["starred2": ["song": items.filter { $0.type == "Audio" }.map(Self.song),
                                 "album": items.filter { $0.type == "MusicAlbum" }.map(Self.album),
                                 "artist": items.filter { $0.type == "MusicArtist" }.map(Self.artist)]]
        case "getRandomSongs", "getSongsByGenre", "getTopSongs":
            var query = baseQuery(.audio)
            query.startIndex = count("offset", 0)
            query.limit = count(endpoint == "getRandomSongs" ? "size" : "count", 50)
            query.sortBy = [endpoint == "getRandomSongs" ? "Random" : endpoint == "getTopSongs" ? "PlayCount" : "SortName"]
            if endpoint == "getTopSongs" {
                query.sortOrder = .descending
                // Resolve an exact artist before querying tracks; SearchTerm would also match titles.
                let artists = try await collection(.musicArtist, search: value("artist") ?? "", offset: 0, limit: 100)
                guard let artist = artists.first(where: { $0.name?.localizedCaseInsensitiveCompare(value("artist") ?? "") == .orderedSame }) else {
                    return ["topSongs": ["song": []]]
                }
                query.artistIDs = [artist.id]
            }
            if let genre = value("genre") {
                guard let genreID = try await genreID(named: genre) else {
                    return [endpoint == "getRandomSongs" ? "randomSongs" : "songsByGenre": ["song": []]]
                }
                query.genreIDs = [genreID]
            }
            let key = endpoint == "getRandomSongs" ? "randomSongs" : endpoint == "getTopSongs" ? "topSongs" : "songsByGenre"
            return [key: ["song": try await page(query).map(Self.song)]]
        case "getSimilarSongs2":
            return ["similarSongs2": ["song": try await client.instantMix(itemID: id, userID: user.id, limit: count("count", 50)).items.map(Self.song)]]
        case "getLyricsBySongId":
            let lyrics = try await client.lyrics(itemID: id)
            let lines: [[String: Any]] = (lyrics.lyrics ?? []).map { line in
                var result: [String: Any] = ["value": line.text ?? ""]
                if let start = line.start { result["start"] = start / 10_000 }
                return result
            }
            return ["lyricsList": ["structuredLyrics": [["synced": lyrics.metadata?.isSynced ?? lyrics.synced ?? false,
                "offset": (lyrics.metadata?.offset ?? 0) / 10_000,
                "line": lines.isEmpty ? [["value": lyrics.text ?? ""]] : lines]]]]
        default:
            throw AdapterError.unsupported
        }
    }

    enum AdapterError: Error { case unsupported }

    func baseQuery(_ type: JellyfinItemType) -> JellyfinItemsQuery {
        var query = JellyfinItemsQuery()
        query.includeItemTypes = [type]
        query.sortBy = ["SortName"]
        query.fields = ["MediaSources", "Genres", "Overview", "DateCreated", "ChildCount"]
        return query
    }

    func collection(_ type: JellyfinItemType, search: String, offset: Int, limit: Int) async throws -> [JellyfinItem] {
        guard limit > 0 else { return [] }
        var query = baseQuery(type)
        query.searchTerm = search
        query.startIndex = offset
        query.limit = limit
        return try await page(query)
    }

    /// Fill the requested page even when a server imposes a smaller per-request limit.
    func page(_ query: JellyfinItemsQuery) async throws -> [JellyfinItem] {
        var query = query
        let requested = query.limit ?? 500
        guard requested > 0 else { return [] }
        var items: [JellyfinItem] = []
        while items.count < requested {
            try Task.checkCancellation()
            query.limit = min(500, requested - items.count)
            let result = try await client.items(userID: user.id, query: query)
            guard !result.items.isEmpty else { break }
            items.append(contentsOf: result.items)
            query.startIndex = (query.startIndex ?? 0) + result.items.count
            if let total = result.totalRecordCount, (query.startIndex ?? 0) >= total { break }
            if result.totalRecordCount == nil, result.items.count < (query.limit ?? 500) { break }
        }
        return Array(items.prefix(requested))
    }

    func all(_ query: JellyfinItemsQuery) async throws -> [JellyfinItem] {
        var query = query
        query.limit = 500
        var items: [JellyfinItem] = []
        while true {
            let batch = try await page(query)
            items.append(contentsOf: batch)
            if batch.count < 500 { return items }
            query.startIndex = (query.startIndex ?? 0) + batch.count
        }
    }

    private func genreID(named name: String) async throws -> String? {
        var query = JellyfinItemsQuery()
        query.searchTerm = name
        query.limit = 100
        query.startIndex = 0
        while true {
            try Task.checkCancellation()
            let result = try await client.genres(query: query)
            if let match = result.items.first(where: { $0.name?.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
                return match.id
            }
            guard !result.items.isEmpty else { return nil }
            query.startIndex = (query.startIndex ?? 0) + result.items.count
            if let total = result.totalRecordCount, (query.startIndex ?? 0) >= total { return nil }
            if result.totalRecordCount == nil, result.items.count < 100 { return nil }
        }
    }

    func playlistEntries(_ id: String) async throws -> [JellyfinItem] {
        var entries: [JellyfinItem] = []
        while true {
            try Task.checkCancellation()
            let result = try await client.playlistItems(playlistID: id, userID: user.id, startIndex: entries.count, limit: 500)
            if result.items.isEmpty { return entries }
            entries.append(contentsOf: result.items)
            if let total = result.totalRecordCount {
                if entries.count >= total { return entries }
            } else if result.items.count < 500 { return entries }
        }
    }

    private func playlistDetail(_ id: String) async throws -> [String: Any] {
        let item = try await client.item(itemID: id, userID: user.id)
        let info = try await client.playlist(playlistID: id)
        let entries = try await playlistEntries(id)
        var result = Self.playlist(item)
        result["public"] = info.openAccess
        result["entry"] = entries.map(Self.song)
        result["songCount"] = entries.count
        result["duration"] = entries.reduce(0) { $0 + Self.seconds($1) }
        return result
    }
}
