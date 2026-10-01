// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import OSLog
import SwiftSonic

/// Lightweight local catalog index for faster search + AI context.
/// Persists songs, artists, albums and playlists per server; search never needs a catalog request.
@MainActor
@Observable
final class LibraryIndexService {
    private(set) var isIndexing = false
    private(set) var lastIndexedAt: Date?
    private(set) var entryCount = 0
    private(set) var progress: Double = 0

    private var artists: [IndexedArtist] = []
    private var albums: [IndexedAlbum] = []
    private var playlists: [IndexedPlaylist] = []
    private var songs: [DisplayableSong] = []
    private var songTokens: [[String]] = []
    private var artistTokens: [[String]] = []
    private var albumTokens: [[String]] = []
    private var playlistTokens: [[String]] = []
    private var generation: UInt64 = 0
    private var loadedServerID: UUID?
    private let serverID: @MainActor () -> UUID?
    private let networkAvailable: @MainActor () -> Bool
    private let directory: URL?

    init(serverID: @escaping @MainActor () -> UUID? = { nil }, networkAvailable: @escaping @MainActor () -> Bool = { true }, directory: URL? = nil) {
        self.serverID = serverID
        self.networkAvailable = networkAvailable
        self.directory = directory
    }

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("app.cassette/library-index", isDirectory: true)
    }

    nonisolated struct Snapshot: Codable, Sendable {
        var artists: [IndexedArtist]
        var albums: [IndexedAlbum]
        var playlists: [IndexedPlaylist]
        var songs: [DisplayableSong]
        var date: Date
    }

    private var indexTask: Task<Void, Never>?

    nonisolated struct IndexedArtist: Sendable, Codable {
        let id: String
        let name: String
        let coverArtId: String?
    }

    nonisolated struct IndexedAlbum: Sendable, Codable {
        let id: String
        let name: String
        let artist: String?
        let coverArtId: String?
    }

    nonisolated struct IndexedPlaylist: Sendable, Codable {
        let id: String
        let name: String
        let coverArtId: String?
    }

    struct LocalHits: Sendable {
        var artists: [IndexedArtist]
        var albums: [IndexedAlbum]
        var playlists: [IndexedPlaylist]
        var songs: [DisplayableSong] = []
    }

    /// Rebuilds the in-memory index. Safe to call repeatedly; overlapping runs are cancelled.
    func rebuild(using library: any LibraryServiceProtocol) {
        indexTask?.cancel()
        generation &+= 1
        let token = generation
        indexTask = Task { [weak self] in
            await self?.runRebuild(using: library, token: token)
        }
    }

    func clear() {
        indexTask?.cancel()
        indexTask = nil
        generation &+= 1
        // Logout clears every account; keep no persisted catalog from a previously selected server.
        if let directory, FileManager.default.fileExists(atPath: directory.path) {
            do { try FileManager.default.removeItem(at: directory) }
            catch { Logger.library.error("Unable to clear stored library indexes: \(error, privacy: .public)") }
        }
        loadedServerID = nil
        songs = []
        songTokens = []
        artistTokens = []; albumTokens = []; playlistTokens = []
        artists = []
        albums = []
        playlists = []
        entryCount = 0
        lastIndexedAt = nil
        isIndexing = false
        progress = 0
    }

    /// Awaits a full index rebuild, updating progress as each catalog phase completes.
    /// Used by the onboarding preparation screen.
    func rebuildAndWait(using library: any LibraryServiceProtocol) async {
        rebuild(using: library)
        await indexTask?.value
    }

    /// Starts a rebuild only when the index is empty — used on Search first entry.
    func ensureIndexed(using library: any LibraryServiceProtocol) {
        if loadedServerID == serverID(), (lastIndexedAt != nil || isIndexing) { return }
        rebuild(using: library)
    }

    func search(query: String, limit: Int = 20) -> LocalHits {
        let queryTokens = HangulRomanization.searchTokens(query)
        guard !queryTokens.isEmpty else {
            return LocalHits(artists: [], albums: [], playlists: [])
        }

        func matches(_ tokens: [String]) -> Bool {
            queryTokens.contains { query in tokens.contains { $0.contains(query) } }
        }
        func collect<T>(_ values: [T], tokens: [[String]]) -> [T] {
            guard limit > 0 else { return [] }
            var result: [T] = []
            for (value, terms) in zip(values, tokens) where matches(terms) {
                result.append(value)
                if result.count == limit { break }
            }
            return result
        }
        let matchedArtists = collect(artists, tokens: artistTokens)
        let matchedAlbums = collect(albums, tokens: albumTokens)
        let matchedPlaylists = collect(playlists, tokens: playlistTokens)

        return LocalHits(
            artists: Array(matchedArtists),
            albums: Array(matchedAlbums),
            playlists: Array(matchedPlaylists),
            songs: Array(zip(songs, songTokens).lazy.filter { _, tokens in
                queryTokens.contains { q in tokens.contains { $0.contains(q) } }
            }.prefix(limit).map { $0.0 })
        )
    }

    /// Compact catalog digest for on-device AI prompts (capped).
    func catalogDigest(limit: Int = 40) -> String {
        let artistNames = artists.prefix(limit).map(\.name)
        let albumNames = albums.prefix(limit).map(\.name)
        guard !artistNames.isEmpty || !albumNames.isEmpty else { return "" }
        return """
        Library sample — artists: \(artistNames.joined(separator: ", ")).
        Albums: \(albumNames.joined(separator: ", ")).
        """
    }

    private func install(_ snapshot: Snapshot, token: UInt64, server: UUID?) async -> Bool {
        // Romanizing a large library is CPU work, so do it once off the UI/audio coordination actor.
        let tokens = await Task.detached(priority: .utility) {
            (snapshot.artists.map { HangulRomanization.searchTokens($0.name) },
             snapshot.albums.map { HangulRomanization.searchTokens([$0.name, $0.artist ?? ""].joined(separator: " ")) },
             snapshot.playlists.map { HangulRomanization.searchTokens($0.name) },
             snapshot.songs.map { HangulRomanization.searchTokens([$0.title, $0.artist ?? "", $0.albumName ?? ""].joined(separator: " ")) })
        }.value
        guard token == generation, server == serverID(), !Task.isCancelled else { return false }
        artists = snapshot.artists
        albums = snapshot.albums
        playlists = snapshot.playlists
        songs = snapshot.songs
        (artistTokens, albumTokens, playlistTokens, songTokens) = tokens
        entryCount = artists.count + albums.count + playlists.count + songs.count
        lastIndexedAt = snapshot.date
        return true
    }

    private func runRebuild(using library: any LibraryServiceProtocol, token: UInt64) async {
        let id = serverID()
        if loadedServerID != id {
            artists = []; albums = []; playlists = []; songs = []; songTokens = []
            artistTokens = []; albumTokens = []; playlistTokens = []
            entryCount = 0; lastIndexedAt = nil
        }
        loadedServerID = id
        isIndexing = true
        progress = 0
        defer { if token == generation { isIndexing = false; indexTask = nil } }
        let file = id.flatMap { id in directory?.appendingPathComponent("\(id).json") }
        if lastIndexedAt == nil, let file {
            let stored = await Task.detached(priority: .utility) {
                guard let data = try? Data(contentsOf: file) else { return nil as Snapshot? }
                return try? JSONDecoder().decode(Snapshot.self, from: data)
            }.value
            guard token == generation, id == serverID(), !Task.isCancelled else { return }
            if let stored { guard await install(stored, token: token, server: id) else { return } }
        }
        guard networkAvailable() else { return }
        do {
            async let artistsTask = library.artists()
            async let albumsTask = library.allAlbums()
            async let playlistsTask = library.playlists()
            let artistIndexes = try await artistsTask
            let albumList = try await albumsTask
            let playlistList = try await playlistsTask
            var indexedSongs: [DisplayableSong] = []
            var seen = Set<String>()
            var offset = 0
            while true {
                try Task.checkCancellation()
                guard token == generation, id == serverID() else { return }
                let page = try await library.librarySongs(offset: offset, count: 500)
                let fresh = page.filter { seen.insert($0.id).inserted }
                guard !fresh.isEmpty else { break }
                indexedSongs += fresh.map { DisplayableSong(from: $0) }
                offset += page.count
                // Some servers cap counts below the request. Stop on empty/repeated data, not a short page.
            }
            try Task.checkCancellation()
            guard token == generation, id == serverID() else { return }
            let snapshot = Snapshot(
                artists: artistIndexes.flatMap(\.artist).map { IndexedArtist(id: $0.id, name: $0.name, coverArtId: $0.coverArt) },
                albums: albumList.map { IndexedAlbum(id: $0.id, name: $0.name, artist: $0.artist, coverArtId: $0.coverArt) },
                playlists: playlistList.map { IndexedPlaylist(id: $0.id, name: $0.name, coverArtId: $0.coverArt) },
                songs: indexedSongs, date: Date()
            )
            guard await install(snapshot, token: token, server: id) else { return }
            progress = 1
            if let file {
                // Actor-isolated commit fences account switches and superseded passes.
                let data = try await Task.detached(priority: .utility) { try JSONEncoder().encode(snapshot) }.value
                guard token == generation, id == serverID(), !Task.isCancelled else { return }
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: file, options: .atomic)
            }
            LibraryIndexSchema.markPrepared()
        } catch is CancellationError {
        } catch {
            Logger.library.debug("Library index rebuild failed: \(error, privacy: .public)")
        }
    }

}

// MARK: - Library index schema version

/// Tracks whether the in-memory library index has been built for the current schema
/// version. Users who upgraded from a build that predates library indexing start with an
/// empty index, so RootView routes them to the "Preparing Cassette" screen once to index
/// their catalog before Home appears.
enum LibraryIndexSchema {
    static let versionKey = "cassette.libraryIndex.schemaVersion"
    /// Bump when the index contents change shape so existing installs re-index once.
    static let currentVersion = 2

    static var needsPreparation: Bool {
        UserDefaults.standard.integer(forKey: versionKey) < currentVersion
    }

    static func markPrepared() {
        UserDefaults.standard.set(currentVersion, forKey: versionKey)
    }
}
