// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import SwiftSonic
import CoreSpotlight
import AppIntents
import OSLog

/// Siri-facing catalog facade.
///
/// Search is **local-first** so a Siri request never blocks on a full library
/// fetch: songs come from `LibraryMetadataStore` (persistent, warmed on every
/// search), albums/artists/playlists from the existing in-memory
/// `LibraryIndexService`, with `search3`/server endpoints as the fallback.
@available(iOS 27.0, macOS 27.0, *)
@MainActor
final class SiriCatalogService: SiriCatalogServiceProtocol {
    private let libraryService: any LibraryServiceProtocol
    private let metadataStore: LibraryMetadataStore
    private let libraryIndex: LibraryIndexService
    private let serverState: ServerState
    private let mediaIdentityService: MediaIdentityService?
    private var remoteSearchCache: (key: String, fetchedAt: Date, result: SearchResult3)?
    private var inFlightRemoteSearch: (key: String, task: Task<SearchResult3?, Never>)?
    private var spotlightIndexedKeys = Set<String>()

    private static let remoteSearchCacheLifetime: TimeInterval = 15

    init(
        libraryService: any LibraryServiceProtocol,
        metadataStore: LibraryMetadataStore,
        libraryIndex: LibraryIndexService,
        serverState: ServerState,
        mediaIdentityService: MediaIdentityService? = nil
    ) {
        self.libraryService = libraryService
        self.metadataStore = metadataStore
        self.libraryIndex = libraryIndex
        self.serverState = serverState
        self.mediaIdentityService = mediaIdentityService
    }

    private func resolveServerId() async -> UUID? {
        await SiriBootGate.waitUntilReady()
        return serverState.activeServer?.id
    }

    /// Entity identifiers are scoped to a server. Never resolve an identifier
    /// from an old account against the currently active server.
    private func isActive(_ id: CassetteEntityID) async -> Bool {
        await resolveServerId() == id.serverId
    }

    /// A single AudioSearch asks for songs, albums, and artists separately. Coalesce
    /// those lookups so one spoken query produces one `search3` request, not three.
    private func remoteSearch(_ query: String, serverId: UUID) async -> SearchResult3? {
        let normalized = query.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
        let key = "\(serverId.uuidString):\(normalized)"
        if let cached = remoteSearchCache,
           cached.key == key,
           Date().timeIntervalSince(cached.fetchedAt) < Self.remoteSearchCacheLifetime {
            return cached.result
        }
        if let inFlightRemoteSearch, inFlightRemoteSearch.key == key {
            return await inFlightRemoteSearch.task.value
        }

        let task = Task { [libraryService] in
            try? await libraryService.search(query)
        }
        inFlightRemoteSearch = (key, task)
        let result = await task.value
        if inFlightRemoteSearch?.key == key { inFlightRemoteSearch = nil }
        if let result { remoteSearchCache = (key, Date(), result) }
        return result
    }

    /// Search-driven indexing is useful, but writing the same entity on every Siri
    /// resolution wastes CPU and Spotlight/XPC work. Keep a small per-process dedupe set.
    private func indexIncrementally<Entity: IndexedEntity>(
        _ entities: [Entity],
        namespace: String
    ) async {
        let pending = entities.filter {
            !spotlightIndexedKeys.contains("\(namespace):\(String(describing: $0.id))")
        }
        guard !pending.isEmpty else { return }
        do {
            try await CSSearchableIndex(name: CassetteSpotlight.indexName).indexAppEntities(pending)
            spotlightIndexedKeys.formUnion(
                pending.map { "\(namespace):\(String(describing: $0.id))" }
            )
        } catch {
            Logger.siri.debug("[SIRI-INDEX] incremental index failed: \(error, privacy: .public)")
        }
    }

    private func rememberIndexed<Entity: IndexedEntity>(
        _ entities: [Entity],
        namespace: String
    ) {
        spotlightIndexedKeys.formUnion(
            entities.map { "\(namespace):\(String(describing: $0.id))" }
        )
    }

    // MARK: - Songs

    func songs(matching query: String, limit: Int) async -> [CassetteSongEntity] {
        guard let serverId = await resolveServerId() else { return [] }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }

        var songs = metadataStore.matching(q, serverId: serverId, limit: limit)

        // `search3` is authoritative for a query. Always merge it so a thin or
        // partially-warmed local cache can't fill the page with weak matches and push
        // the requested track out (or suppress the fallback entirely). Server hits go
        // first, then local hits fill any remaining slots.
        if let remote = await remoteSearch(q, serverId: serverId)?.song {
            let mapped = remote.map { DisplayableSong(from: $0) }
            metadataStore.upsert(mapped, serverId: serverId)
            var seen = Set<String>()
            var merged: [DisplayableSong] = []
            for song in mapped + songs {
                guard !seen.contains(song.id) else { continue }
                seen.insert(song.id)
                merged.append(song)
            }
            // Never trust server order as the final Siri choice. Rank fresh and cached
            // candidates together so album words and unrequested variant suffixes count.
            songs = merged.enumerated().sorted { lhs, rhs in
                let lhsScore = SiriSongSearchRanker.score(lhs.element, query: q)
                let rhsScore = SiriSongSearchRanker.score(rhs.element, query: q)
                if lhsScore != rhsScore { return lhsScore > rhsScore }
                return lhs.offset < rhs.offset
            }.map(\.element)
        }

        let entities = songs
            .prefix(limit)
            .map { CassetteSongEntity(song: $0, serverId: serverId, loadRelations: true) }
        await indexIncrementally(entities, namespace: "song")
        return entities
    }

    func song(id: CassetteEntityID) async -> CassetteSongEntity? {
        guard await isActive(id) else { return nil }
        let currentID = mediaIdentityService?.resolveCurrentID(id.localId, serverId: id.serverId, entityType: .song) ?? id.localId
        if let song = metadataStore.song(id: id.localId, serverId: id.serverId)
            ?? metadataStore.song(id: currentID, serverId: id.serverId) {
            return CassetteSongEntity(song: song, serverId: id.serverId, loadRelations: true)
        }
        guard let remote = try? await libraryService.song(id: currentID) else { return nil }
        let song = DisplayableSong(from: remote)
        metadataStore.upsert([song], serverId: id.serverId)
        return CassetteSongEntity(song: song, serverId: id.serverId, loadRelations: true)
    }

    // MARK: - Albums

    func albums(matching query: String, limit: Int) async -> [CassetteAlbumEntity] {
        guard let serverId = await resolveServerId() else { return [] }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)

        libraryIndex.ensureIndexed(using: libraryService)
        let localHits = libraryIndex.search(query: q, limit: limit)
        var results = localHits.albums.map {
            CassetteAlbumEntity(
                id: CassetteEntityID(serverId: serverId, localId: $0.id).rawValue,
                title: $0.name,
                artistName: CassetteEntityDisplay.artistName($0.artist),
                artists: $0.artist.map { [CassetteArtistEntity(serverId: serverId, name: $0)] } ?? []
            )
        }

        if results.count < limit {
            if let remote = await remoteSearch(q, serverId: serverId)?.album {
                let seen = Set(results.map(\.id))
                results += remote.compactMap { album in
                    let entity = CassetteAlbumEntity(album: album, serverId: serverId, loadRelations: false)
                    return seen.contains(entity.id) ? nil : entity
                }
            }
        }
        let entities = Array(results.prefix(limit))
        await indexIncrementally(entities, namespace: "album")
        return entities
    }

    func album(id: CassetteEntityID) async -> CassetteAlbumEntity? {
        guard await isActive(id) else { return nil }
        let currentID = mediaIdentityService?.resolveCurrentID(id.localId, serverId: id.serverId, entityType: .album) ?? id.localId
        guard let album = try? await libraryService.album(id: currentID) else { return nil }
        return CassetteAlbumEntity(album: album, serverId: id.serverId, loadRelations: false)
    }
    // MARK: - Artists

    func artists(matching query: String, limit: Int) async -> [CassetteArtistEntity] {
        guard let serverId = await resolveServerId() else { return [] }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)

        libraryIndex.ensureIndexed(using: libraryService)
        let localHits = libraryIndex.search(query: q, limit: limit)
        var results = localHits.artists.map {
            CassetteArtistEntity(
                id: CassetteEntityID(serverId: serverId, localId: $0.id).rawValue,
                name: $0.name
            )
        }

        if results.count < limit {
            if let remote = await remoteSearch(q, serverId: serverId)?.artist {
                let seen = Set(results.map(\.id))
                results += remote.compactMap { artist in
                    let entity = CassetteArtistEntity(artist: artist, serverId: serverId)
                    return seen.contains(entity.id) ? nil : entity
                }
            }
        }
        let entities = Array(results.prefix(limit))
        await indexIncrementally(entities, namespace: "artist")
        return entities
    }

    func artist(id: CassetteEntityID) async -> CassetteArtistEntity? {
        guard await isActive(id) else { return nil }
        let currentID = mediaIdentityService?.resolveCurrentID(id.localId, serverId: id.serverId, entityType: .artist) ?? id.localId
        guard let artist = try? await libraryService.artist(id: currentID) else { return nil }
        return CassetteArtistEntity(artist: artist, serverId: id.serverId)
    }

    // MARK: - Playlists

    func playlists(matching query: String, limit: Int) async -> [CassettePlaylistEntity] {
        guard let serverId = await resolveServerId() else { return [] }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)

        libraryIndex.ensureIndexed(using: libraryService)
        let localHits = libraryIndex.search(query: q, limit: limit)
        var results = localHits.playlists.map {
            CassettePlaylistEntity(
                id: CassetteEntityID(serverId: serverId, localId: $0.id).rawValue,
                title: $0.name
            )
        }

        if results.count < limit {
            if let remote = try? await libraryService.playlists() {
                let seen = Set(results.map(\.id))
                results += remote
                    .filter { $0.name.localizedCaseInsensitiveContains(q) }
                    .prefix(limit)
                    .compactMap { playlist in
                        let entity = CassettePlaylistEntity(playlist: playlist, serverId: serverId)
                        return seen.contains(entity.id) ? nil : entity
                    }
            }
        }
        let entities = Array(results.prefix(limit))
        await indexIncrementally(entities, namespace: "playlist")
        return entities
    }

    func playlist(id: CassetteEntityID) async -> CassettePlaylistEntity? {
        guard await isActive(id) else { return nil }
        let currentID = mediaIdentityService?.resolveCurrentID(id.localId, serverId: id.serverId, entityType: .playlist) ?? id.localId
        guard let playlists = try? await libraryService.playlists() else { return nil }
        guard let playlist = playlists.first(where: { $0.id == currentID }) else { return nil }
        return CassettePlaylistEntity(playlist: playlist, serverId: id.serverId)
    }

    // MARK: - Suggestions (open-ended "play some music")

    func suggestedSongs(limit: Int) async -> [CassetteSongEntity] {
        guard let serverId = await resolveServerId() else { return [] }

        // Prefer songs the person already endorsed; fall back to random.
        let songs: [Song]
        if let starred = try? await libraryService.getStarred2().song, !starred.isEmpty {
            songs = Array(starred.prefix(limit))
        } else {
            songs = (try? await libraryService.randomSongs(size: limit)) ?? []
        }

        let mapped = songs.map { DisplayableSong(from: $0) }
        metadataStore.upsert(mapped, serverId: serverId)
        return mapped.prefix(limit).map {
            CassetteSongEntity(song: $0, serverId: serverId, loadRelations: true)
        }
    }

    // MARK: - Playback resolution

    func playableSong(id: CassetteEntityID) async -> DisplayableSong? {
        guard await isActive(id) else { return nil }
        let currentID = mediaIdentityService?.resolveCurrentID(id.localId, serverId: id.serverId, entityType: .song) ?? id.localId
        if let song = metadataStore.song(id: id.localId, serverId: id.serverId)
            ?? metadataStore.song(id: currentID, serverId: id.serverId) {
            return song
        }
        guard let remote = try? await libraryService.song(id: currentID) else { return nil }
        let song = DisplayableSong(from: remote)
        metadataStore.upsert([song], serverId: id.serverId)
        return song
    }

    /// Full SwiftSonic `Song` record, used by playlist additions.
    func songRecord(id: CassetteEntityID) async -> Song? {
        guard await isActive(id) else { return nil }
        let currentID = mediaIdentityService?.resolveCurrentID(id.localId, serverId: id.serverId, entityType: .song) ?? id.localId
        return try? await libraryService.song(id: currentID)
    }

    // MARK: - Bounded full-catalog listings (Spotlight reindex)

    func allSongs(limit: Int) async -> [CassetteSongEntity] {
        guard let serverId = await resolveServerId() else { return [] }
        let songs = (try? await libraryService.librarySongs(offset: 0, count: limit)) ?? []
        return songs.map { CassetteSongEntity(song: DisplayableSong(from: $0), serverId: serverId, loadRelations: true) }
    }

    func allAlbums(limit: Int) async -> [CassetteAlbumEntity] {
        guard let serverId = await resolveServerId() else { return [] }
        let albums = (try? await libraryService.allAlbums()) ?? []
        return albums.prefix(limit).map { CassetteAlbumEntity(album: $0, serverId: serverId, loadRelations: false) }
    }

    func allArtists(limit: Int) async -> [CassetteArtistEntity] {
        guard let serverId = await resolveServerId() else { return [] }
        let indexes = (try? await libraryService.artists()) ?? []
        let artists = indexes.flatMap(\.artist)
        return artists.prefix(limit).map { CassetteArtistEntity(artist: $0, serverId: serverId) }
    }

    func allPlaylists(limit: Int) async -> [CassettePlaylistEntity] {
        guard let serverId = await resolveServerId() else { return [] }
        let playlists = (try? await libraryService.playlists()) ?? []
        return playlists.prefix(limit).map { CassettePlaylistEntity(playlist: $0, serverId: serverId) }
    }

    func playableSongs(inAlbum id: CassetteEntityID) async -> [DisplayableSong] {
        guard await isActive(id) else { return [] }
        guard let album = try? await libraryService.album(id: id.localId) else { return [] }
        return (album.song ?? []).map { DisplayableSong(from: $0) }
    }

    func playableSongs(byArtist id: CassetteEntityID) async -> [DisplayableSong] {
        guard await isActive(id) else { return [] }
        return (try? await libraryService.fetchAllTracks(forArtistID: id.localId)) ?? []
    }

    func playableSongs(inPlaylist id: CassetteEntityID) async -> [DisplayableSong] {
        guard await isActive(id) else { return [] }
        guard let playlist = try? await libraryService.playlist(id: id.localId) else { return [] }
        return (playlist.entry ?? []).map { DisplayableSong(from: $0) }
    }

    // MARK: - Library warmup

    /// Caps the one-time warmup so a very large server can't stall Siri boot.
    private static let warmupEntityLimit = 1_000

    /// Warms the song-metadata store and reindexes Spotlight once per server.
    ///
    /// The metadata store normally grows incrementally from search results, but that
    /// leaves Siri unable to resolve “the current song” or a named artist/playlist on
    /// a fresh install / fresh login — which surfaces as “couldn't get the data to
    /// process”. This runs a bounded full pass so the first Siri request resolves.
    func warmLibraryForSiri() async {
        guard let serverId = await resolveServerId() else { return }
        let needsMetadataWarmup = metadataStore.count(serverId: serverId) == 0
        let needsSpotlightWarmup = !CassetteSpotlight.isWarm(for: serverId)
        guard needsMetadataWarmup || needsSpotlightWarmup else {
            Logger.siri.debug("[SIRI-WARM] metadata and Spotlight already warm — skipping")
            return
        }

        Logger.siri.info("[SIRI-WARM] warming library for server \(serverId.uuidString, privacy: .public)")

        // 1. Persistent song store — lets "like this song" / song lookups resolve locally.
        var warmedSongs: [DisplayableSong] = []
        if needsMetadataWarmup,
           let songs = try? await libraryService.librarySongs(offset: 0, count: Self.warmupEntityLimit),
           !songs.isEmpty {
            warmedSongs = songs.map { DisplayableSong(from: $0) }
            metadataStore.upsert(warmedSongs, serverId: serverId)
            Logger.siri.info("[SIRI-WARM] upserted \(songs.count, privacy: .public) songs")
        }

        // 2. Spotlight — lets Siri map names ("Michael Jackson", "my playlist") to entities.
        if needsSpotlightWarmup {
            do {
                let index = CSSearchableIndex(name: CassetteSpotlight.indexName)
                let songEntities = warmedSongs.isEmpty
                    ? await allSongs(limit: Self.warmupEntityLimit)
                    : warmedSongs.map {
                        CassetteSongEntity(song: $0, serverId: serverId, loadRelations: true)
                    }
                if !songEntities.isEmpty {
                    try await index.indexAppEntities(songEntities)
                    rememberIndexed(songEntities, namespace: "song")
                }
                let albumEntities = await allAlbums(limit: Self.warmupEntityLimit)
                if !albumEntities.isEmpty {
                    try await index.indexAppEntities(albumEntities)
                    rememberIndexed(albumEntities, namespace: "album")
                }
                let artistEntities = await allArtists(limit: Self.warmupEntityLimit)
                if !artistEntities.isEmpty {
                    try await index.indexAppEntities(artistEntities)
                    rememberIndexed(artistEntities, namespace: "artist")
                }
                let playlistEntities = await allPlaylists(limit: Self.warmupEntityLimit)
                if !playlistEntities.isEmpty {
                    try await index.indexAppEntities(playlistEntities)
                    rememberIndexed(playlistEntities, namespace: "playlist")
                }
                CassetteSpotlight.markWarm(for: serverId)
                Logger.siri.info("[SIRI-WARM] Spotlight reindex complete")
            } catch {
                Logger.siri.error("[SIRI-WARM] Spotlight reindex failed: \(error, privacy: .public)")
            }
        }
    }
}
