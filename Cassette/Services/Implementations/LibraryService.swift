// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import SwiftData
import SwiftSonic
import OSLog

actor LibraryService: LibraryServiceProtocol {
    private let serverService: any ServerServiceProtocol
    private let modelContainer: ModelContainer
    private let downloadService: any DownloadServiceProtocol
    private let statsService: StatsService
    private var cachedClient: SwiftSonicClient?
    private var artistNameIndex: [String: ArtistID3]?
    private var indexBuildTask: Task<Void, Never>?
    private var artistInfoCache: [String: ArtistInfo] = [:]
    /// Short-lived detail caches — cut repeat getArtist/getAlbum when album↔artist navigation stacks.
    private var artistDetailCache: [String: ArtistID3] = [:]
    private var albumDetailCache: [String: AlbumID3] = [:]
    private var artistInFlight: [String: Task<ArtistID3, Error>] = [:]
    private var albumInFlight: [String: Task<AlbumID3, Error>] = [:]
    /// Similar-artist counts satisfied by each cached ArtistInfo (so count:0 can't block count:20).
    private var artistInfoCachedCount: [String: Int] = [:]
    /// Coalesce concurrent getAlbumList2 / getStarred2 (Home + Library + Discover stampede).
    private var albumListCache: [String: [AlbumID3]] = [:]
    private var albumListInFlight: [String: Task<[AlbumID3], Error>] = [:]
    private var starred2InFlight: Task<Starred2, Error>?
    private var starred2Cached: Starred2?
    private var starred2CachedAt: Date?
    nonisolated private static let starred2TTL: TimeInterval = 30
    nonisolated private static let albumListTTL: TimeInterval = 45
    nonisolated private static let allAlbumsTTL: TimeInterval = 60
    private var albumListCachedAt: [String: Date] = [:]
    /// Full-library `allAlbums()` coalescing — cover-preload reconcile, the Albums list, the
    /// library index and Add Music all fetch the whole catalog at launch. Without this each
    /// one independently re-pages the library and storms `getAlbumList2`.
    private var allAlbumsCached: [AlbumID3]?
    private var allAlbumsCachedAt: Date?
    private var allAlbumsInFlight: Task<[AlbumID3], Error>?

    init(
        serverService: any ServerServiceProtocol,
        modelContainer: ModelContainer,
        downloadService: any DownloadServiceProtocol,
        statsService: StatsService
    ) {
        self.serverService = serverService
        self.modelContainer = modelContainer
        self.downloadService = downloadService
        self.statsService = statsService
    }

    private func client() async throws -> SwiftSonicClient {
        // Fast path: cached client returned without touching the MainActor.
        // The periodic player time observer fires on the MainActor every 0.5s during playback,
        // so any await MainActor.run on the hot path causes multi-second stalls.
        if let cached = cachedClient {
            Logger.library.debug("[CLIENT] cache hit")
            return cached
        }
        Logger.library.debug("[CLIENT] cache miss → makeSwiftSonicClient")
        let fresh = try await serverService.makeSwiftSonicClient()
        Logger.library.debug("[CLIENT] ← makeSwiftSonicClient done")
        cachedClient = fresh
        artistInfoCache = [:]
        artistInfoCachedCount = [:]
        artistDetailCache = [:]
        albumDetailCache = [:]
        artistInFlight = [:]
        albumInFlight = [:]
        albumListCache = [:]
        albumListCachedAt = [:]
        albumListInFlight = [:]
        allAlbumsCached = nil
        allAlbumsCachedAt = nil
        allAlbumsInFlight = nil
        starred2InFlight = nil
        starred2Cached = nil
        starred2CachedAt = nil
        artistNameIndex = nil
        indexBuildTask = nil
        return fresh
    }

    func invalidateClientCache() async {
        cachedClient = nil
        artistInfoCache = [:]
        artistInfoCachedCount = [:]
        artistDetailCache = [:]
        albumDetailCache = [:]
        for task in artistInFlight.values { task.cancel() }
        for task in albumInFlight.values { task.cancel() }
        for task in albumListInFlight.values { task.cancel() }
        starred2InFlight?.cancel()
        artistInFlight = [:]
        albumInFlight = [:]
        albumListCache = [:]
        albumListCachedAt = [:]
        albumListInFlight = [:]
        allAlbumsCached = nil
        allAlbumsCachedAt = nil
        allAlbumsInFlight?.cancel()
        allAlbumsInFlight = nil
        starred2InFlight = nil
        starred2Cached = nil
        starred2CachedAt = nil
        artistNameIndex = nil
        indexBuildTask?.cancel()
        indexBuildTask = nil
        Logger.library.debug("[CLIENT] cache invalidated")
    }

    func artists() async throws -> [ArtistIndex] {
        try await client().getArtists()
    }

    func artist(id: String) async throws -> ArtistID3 {
        if let cached = artistDetailCache[id] {
            Logger.library.debug("[ARTIST] cache hit id=\(id, privacy: .public)")
            return cached
        }
        if let existing = artistInFlight[id] {
            Logger.library.debug("[ARTIST] coalesce in-flight id=\(id, privacy: .public)")
            return try await existing.value
        }

        Logger.library.debug("[ARTIST] artist(id:) START id=\(id, privacy: .public)")
        let task = Task<ArtistID3, Error> {
            let c = try await self.client()
            Logger.library.debug("[ARTIST] → client().getArtist")
            let t0 = Date()
            let result = try await c.getArtist(id: id)
            let elapsed = String(format: "%.2f", Date().timeIntervalSince(t0))
            Logger.library.debug("[ARTIST] ← client().getArtist done \(elapsed, privacy: .public)s")
            return result
        }
        artistInFlight[id] = task
        defer { artistInFlight[id] = nil }

        do {
            let result = try await task.value
            artistDetailCache[id] = result
            return result
        } catch {
            throw error
        }
    }

    func album(id: String) async throws -> AlbumID3 {
        if let cached = albumDetailCache[id] {
            Logger.library.debug("[ALBUM] cache hit id=\(id, privacy: .public)")
            return cached
        }
        if let existing = albumInFlight[id] {
            Logger.library.debug("[ALBUM] coalesce in-flight id=\(id, privacy: .public)")
            return try await existing.value
        }

        let task = Task<AlbumID3, Error> {
            try await self.client().getAlbum(id: id)
        }
        albumInFlight[id] = task
        defer { albumInFlight[id] = nil }

        let result = try await task.value
        albumDetailCache[id] = result
        return result
    }

    func albumInfo(id: String) async throws -> AlbumInfo {
        try await client().getAlbumInfo2(id: id)
    }

    func playlists() async throws -> [Playlist] {
        try await client().getPlaylists()
    }

    func playlist(id: String) async throws -> PlaylistWithSongs {
        try await client().getPlaylist(id: id)
    }

    func search(_ query: String) async throws -> SearchResult3 {
        try await client().search3(query)
    }

    func search(_ query: String, page: SearchPageRequest) async throws -> SearchResult3 {
        try await client().search3(
            query,
            artistCount: page.artistCount, artistOffset: page.artistOffset,
            albumCount: page.albumCount, albumOffset: page.albumOffset,
            songCount: page.songCount, songOffset: page.songOffset
        )
    }

    func song(id: String) async throws -> Song {
        try await client().getSong(id: id)
    }

    func librarySongs(offset: Int, count: Int) async throws -> [Song] {
        try await client().search3("", artistCount: 0, albumCount: 0,
                                   songCount: count, songOffset: offset).song ?? []
    }

    func coverArtURL(id: String, size: Int?) async -> URL? {
        guard let c = try? await client() else { return nil }
        return c.coverArtURL(id: id, size: size)
    }

    func streamURL(songId: String) async -> URL? {
        guard let c = try? await client() else { return nil }
        return c.streamURL(id: songId)
    }

    func star(songIds: [String], albumIds: [String], artistIds: [String]) async throws {
        try await client().star(songIds: songIds, albumIds: albumIds, artistIds: artistIds)
    }

    func unstar(songIds: [String], albumIds: [String], artistIds: [String]) async throws {
        try await client().unstar(songIds: songIds, albumIds: albumIds, artistIds: artistIds)
    }

    func getStarred2() async throws -> Starred2 {
        if let cached = starred2Cached,
           let at = starred2CachedAt,
           Date().timeIntervalSince(at) < Self.starred2TTL {
            return cached
        }
        if let existing = starred2InFlight {
            return try await existing.value
        }
        let task = Task<Starred2, Error> {
            try await self.client().getStarred2()
        }
        starred2InFlight = task
        defer { starred2InFlight = nil }
        let result = try await task.value
        starred2Cached = result
        starred2CachedAt = Date()
        return result
    }

    func recentlyAddedAlbums(size: Int) async throws -> [AlbumID3] {
        try await albumList(typeKey: "newest", size: size) {
            try await $0.getAlbumList2(type: .newest, size: $1)
        }
    }

    func allAlbums() async throws -> [AlbumID3] {
        // Single-flight + short TTL: several launch paths (cover-preload reconcile, Albums list,
        // library index, Add Music) call this independently. Coalesce them so the whole catalog
        // is paged from the server exactly once per TTL instead of N times.
        if let cached = allAlbumsCached,
           let at = allAlbumsCachedAt,
           Date().timeIntervalSince(at) < Self.allAlbumsTTL {
            return cached
        }
        if let existing = allAlbumsInFlight {
            return try await existing.value
        }
        let task = Task<[AlbumID3], Error> {
            try await self.fetchAllAlbums()
        }
        allAlbumsInFlight = task
        defer { allAlbumsInFlight = nil }
        let result = try await task.value
        allAlbumsCached = result
        allAlbumsCachedAt = Date()
        return result
    }

    private func fetchAllAlbums() async throws -> [AlbumID3] {
        Logger.library.info("allAlbums() called")
        do {
            // Subsonic caps `size` at 500, so a single request silently truncates large
            // libraries. Page through the alphabetically-ordered list with `offset` until
            // the server returns a short page (or we hit a sane upper bound).
            let pageSize = 500
            var all: [AlbumID3] = []
            var seen = Set<String>()
            var offset = 0
            // Upper bound safety net (200 pages = 100k albums); break earlier on a short page.
            while offset < pageSize * 200 {
                let client = try await self.client()
                let page = try await client.getAlbumList2(
                    type: .alphabeticalByName,
                    size: pageSize,
                    offset: offset
                )
                // Dedupe by id so a server-side reorder mid-pagination can't double-count.
                let fresh = page.filter { seen.insert($0.id).inserted }
                all.append(contentsOf: fresh)
                Logger.library.debug("allAlbums() page offset=\(offset, privacy: .public) returned=\(page.count, privacy: .public)")
                if page.count < pageSize { break }
                offset += pageSize
            }
            Logger.library.info("allAlbums() done — \(all.count, privacy: .public) items")
            return all
        } catch {
            Logger.library.error("allAlbums() getAlbumList2 error: \(String(describing: error), privacy: .public)")
            Logger.library.error("allAlbums() error type: \(type(of: error), privacy: .public)")
            throw error
        }
    }

    func savePlayQueue(songIds: [String], currentIndex: Int, positionSeconds: Double) async throws {
        // TODO(v1.x): verify Navidrome savePlayQueue support; implement best-effort sync
    }

    func getPlayQueue() async throws -> SavedPlayQueue? {
        // TODO(v1.x): implement best-effort queue restore from server
        return nil
    }

    // MARK: - Artist tracks

    func fetchAllTracks(forArtistID artistID: String) async throws -> [DisplayableSong] {
        let artistDetail = try await artist(id: artistID)
        let albums = (artistDetail.album ?? []).sorted { lhs, rhs in
            switch (lhs.year, rhs.year) {
            case let (y1?, y2?): return y1 > y2
            case (_?, nil):      return true
            case (nil, _?):      return false
            case (nil, nil):     return lhs.name < rhs.name
            }
        }
        guard !albums.isEmpty else { return [] }

        // The downloaded-track index is identical for every album in this request. Fetch it
        // once instead of making every child task scan SwiftData independently (an N+1 query
        // that became very visible for artists with large discographies).
        let serverId = await MainActor.run { serverService.state.activeServer?.id }
        let downloadedIds: Set<String>
        if let serverId {
            downloadedIds = await downloadService.downloadedSongIds(serverId: serverId)
        } else {
            downloadedIds = []
        }

        var collected: [(index: Int, songs: [DisplayableSong])] = []

        await withTaskGroup(of: (Int, [DisplayableSong]?).self) { group in
            var submitted = 0

            while submitted < min(5, albums.count) {
                let i = submitted
                let albumId = albums[i].id
                group.addTask {
                    await self.fetchAlbumTracks(
                        albumId: albumId,
                        index: i,
                        downloadedIds: downloadedIds
                    )
                }
                submitted += 1
            }

            while let (index, songs) = await group.next() {
                if let songs { collected.append((index, songs)) }
                if submitted < albums.count {
                    let i = submitted
                    let albumId = albums[i].id
                    group.addTask {
                        await self.fetchAlbumTracks(
                            albumId: albumId,
                            index: i,
                            downloadedIds: downloadedIds
                        )
                    }
                    submitted += 1
                }
            }
        }

        guard !collected.isEmpty else {
            Logger.library.error("[ARTIST-TRACKS] all fetches failed artistId=\(artistID, privacy: .public)")
            throw CassetteError.artistTracksUnavailable
        }

        Logger.library.debug("[ARTIST-TRACKS] fetched \(collected.count)/\(albums.count) albums artistId=\(artistID, privacy: .public)")
        return collected.sorted { $0.index < $1.index }.flatMap { $0.songs }
    }

    private func fetchAlbumTracks(
        albumId: String,
        index: Int,
        downloadedIds: Set<String>
    ) async -> (Int, [DisplayableSong]?) {
        do {
            let detail = try await album(id: albumId)
            let songs = (detail.song ?? []).map { song in
                DisplayableSong(from: song, isDownloaded: downloadedIds.contains(song.id))
            }
            return (index, songs)
        } catch {
            Logger.library.error("[ARTIST-TRACKS] album \(albumId) fetch failed: \(error, privacy: .public)")
            return (index, nil)
        }
    }

    // MARK: - Discover

    func scrobble(songId: String, submission: Bool) async {
        do {
            try await client().scrobble(id: songId, submission: submission)
            Logger.library.debug("Scrobbled '\(songId, privacy: .public)' submission=\(submission)")
        } catch {
            // Silent failure per Subsonic convention. Log at debug level only — scrobble errors
            // are common (network blips, auth races) and should never surface to the user.
            Logger.library.debug("Scrobble failed for '\(songId, privacy: .public)' submission=\(submission): \(error, privacy: .public)")
        }
    }

    func recentlyPlayedAlbums(size: Int) async throws -> [AlbumID3] {
        try await albumList(typeKey: "recent", size: size) {
            try await $0.getAlbumList2(type: .recent, size: $1)
        }
    }

    func mostPlayedAlbums(size: Int) async throws -> [AlbumID3] {
        try await albumList(typeKey: "frequent", size: size) {
            try await $0.getAlbumList2(type: .frequent, size: $1)
        }
    }

    func randomAlbums(size: Int) async throws -> [AlbumID3] {
        // Random lists are intentionally not long-lived-cached beyond in-flight coalesce.
        try await albumList(typeKey: "random", size: size, cacheTTL: 8) {
            try await $0.getAlbumList2(type: .random, size: $1)
        }
    }

    /// Fetch once at the largest requested size; smaller callers share the same response.
    private func albumList(
        typeKey: String,
        size: Int,
        cacheTTL: TimeInterval = albumListTTL,
        fetch: @escaping (SwiftSonicClient, Int) async throws -> [AlbumID3]
    ) async throws -> [AlbumID3] {
        let cacheKey = typeKey
        if let cached = albumListCache[cacheKey],
           let at = albumListCachedAt[cacheKey],
           Date().timeIntervalSince(at) < cacheTTL {
            return Array(cached.prefix(size))
        }
        if let existing = albumListInFlight[cacheKey] {
            let full = try await existing.value
            return Array(full.prefix(size))
        }

        // Request enough for the largest common shelf (Discover uses 35).
        let requestSize = max(size, 60)
        let task = Task<[AlbumID3], Error> {
            let c = try await self.client()
            return try await fetch(c, requestSize)
        }
        albumListInFlight[cacheKey] = task
        defer { albumListInFlight[cacheKey] = nil }

        let full = try await task.value
        albumListCache[cacheKey] = full
        albumListCachedAt[cacheKey] = Date()
        return Array(full.prefix(size))
    }

    func randomSongs(size: Int) async throws -> [Song] {
        try await client().getRandomSongs(size: size)
    }

    func songsByGenre(_ genre: String, count: Int) async throws -> [DisplayableSong] {
        let songs = try await client().getSongsByGenre(genre, count: count)
        return songs.map { DisplayableSong(from: $0) }
    }

    func smartShuffleQueue(targetSize: Int) async throws -> [DisplayableSong] {
        let isOnline = await MainActor.run { serverService.state.isOnline }
        if isOnline {
            return try await onlineSmartShuffle(targetSize: targetSize)
        } else {
            return await offlineSmartShuffle(targetSize: targetSize)
        }
    }

    private func onlineSmartShuffle(targetSize: Int) async throws -> [DisplayableSong] {
        // Product rule: rediscover is TRULY random — no recency weighting,
        // no `played` filtering. The server picks uniformly across the library.
        let songs = try await client().getRandomSongs(size: targetSize)
        Logger.library.debug("Smart shuffle online: \(songs.count) random tracks (target \(targetSize))")
        return songs.map { DisplayableSong(from: $0) }
    }

    // MARK: - Auto-extend similar backfill

    /// Most recent distinct seed values win; keep fan-out tiny so backfill never
    /// competes with audio streaming (full discography fetches caused underruns).
    nonisolated static let backfillMaxSeedArtists = 3
    nonisolated static let backfillMaxSeedGenres = 3
    nonisolated static let backfillGenreFetchCount = 100
    /// Newest albums only — never walk an entire discography during playback.
    nonisolated static let backfillMaxAlbumsPerArtist = 3
    nonisolated static let backfillAlbumConcurrency = 2

    /// Extracts distinct artist ids and genres from recent plays, newest first.
    nonisolated static func similaritySeeds(
        from events: [PlaybackEventDTO],
        maxArtists: Int = backfillMaxSeedArtists,
        maxGenres: Int = backfillMaxSeedGenres
    ) -> (artistIds: [String], genres: [String]) {
        var artistIds: [String] = []
        var genres: [String] = []
        for event in events {
            if let id = event.artistId, !id.isEmpty, artistIds.count < maxArtists, !artistIds.contains(id) {
                artistIds.append(id)
            }
            if let genre = event.genre, !genre.isEmpty, genres.count < maxGenres, !genres.contains(genre) {
                genres.append(genre)
            }
        }
        return (artistIds, genres)
    }

    /// Shuffles the candidate pool, drops excluded and duplicate ids, and caps at
    /// `targetSize`. Pure — the network-facing caller assembles the inputs.
    nonisolated static func assembleBackfill(
        pool: [DisplayableSong],
        excludedIds: Set<String>,
        targetSize: Int
    ) -> [DisplayableSong] {
        var seen = excludedIds
        var result: [DisplayableSong] = []
        for song in pool.shuffled() where !seen.contains(song.id) {
            seen.insert(song.id)
            result.append(song)
            if result.count == targetSize { break }
        }
        return result
    }

    func similarBackfillQueue(targetSize: Int, excludedIds: Set<String>) async throws -> [DisplayableSong] {
        let isOnline = await MainActor.run { serverService.state.isOnline }
        guard isOnline else {
            // Offline: keep the downloads-only fallback, still honoring exclusions.
            let downloads = await offlineSmartShuffle(targetSize: targetSize + excludedIds.count)
            return Self.assembleBackfill(pool: downloads, excludedIds: excludedIds, targetSize: targetSize)
        }
        guard let serverId = await MainActor.run(body: { serverService.state.activeServer?.id }) else {
            return []
        }

        let recent = await statsService.recentEvents(limit: 20, serverId: serverId.uuidString)
        // Never re-serve what the user just heard.
        var excluded = excludedIds
        for event in recent { excluded.insert(event.trackId) }

        var pool: [DisplayableSong] = []

        // Prefer OpenSubsonic sonicSimilarity (Navidrome 0.62+ / AudioMuse-AI) when available.
        if let seedId = recent.first?.trackId,
           let sonic = await fetchSonicSimilarTracks(seedId: seedId, count: targetSize + 10) {
            pool.append(contentsOf: sonic)
        }

        // No ≥30s listening history yet → degrade to pure random (after sonic attempt).
        let seeds = Self.similaritySeeds(from: recent)
        if !recent.isEmpty {
            // Cheap genre pulls first (one request each) — prefer these over album walks.
            for genre in seeds.genres {
                if let songs = try? await client().getSongsByGenre(genre, count: Self.backfillGenreFetchCount) {
                    pool.append(contentsOf: songs.map { DisplayableSong(from: $0) })
                }
            }
            // Artist candidates: sample a few newest albums only — never full discographies
            // mid-playback (that stampeded getAlbum and starved the audio stream).
            for artistId in seeds.artistIds {
                let tracks = await fetchSampleTracksForBackfill(forArtistID: artistId)
                pool.append(contentsOf: tracks)
            }
        }

        var result = Self.assembleBackfill(pool: pool, excludedIds: excluded, targetSize: targetSize)

        // Thin pool (small library, empty genres) or no history: top up with random.
        if result.count < targetSize {
            let randomSongs = (try? await client().getRandomSongs(size: targetSize + excluded.count)) ?? []
            excluded.formUnion(result.map(\.id))
            let topUp = Self.assembleBackfill(
                pool: randomSongs.map { DisplayableSong(from: $0) },
                excludedIds: excluded,
                targetSize: targetSize - result.count
            )
            result.append(contentsOf: topUp)
        }

        Logger.library.debug("Similar backfill: \(result.count)/\(targetSize) tracks (seeds: \(seeds.artistIds.count) artists, \(seeds.genres.count) genres, recent: \(recent.count))")
        return result
    }

    /// Audio-similarity matches when the server advertises `sonicSimilarity`.
    private func fetchSonicSimilarTracks(seedId: String, count: Int) async -> [DisplayableSong]? {
        do {
            let caps = try await client().loadCapabilities()
            guard caps.supports(.sonicSimilarity) else { return nil }
            let matches = try await client().getSonicSimilarTracks(id: seedId, count: count)
            let songs = matches
                .filter { $0.similarity >= 0 }
                .map { DisplayableSong(from: $0.entry) }
            guard !songs.isEmpty else { return nil }
            Logger.library.debug("Sonic similarity: \(songs.count) matches for seed=\(seedId, privacy: .public)")
            return songs
        } catch {
            Logger.library.debug("Sonic similarity unavailable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Lightweight artist sample for auto-extend — at most `backfillMaxAlbumsPerArtist`
    /// newest albums, low concurrency, no download-status checks.
    private func fetchSampleTracksForBackfill(forArtistID artistID: String) async -> [DisplayableSong] {
        guard let artistDetail = try? await artist(id: artistID) else { return [] }
        let albums = (artistDetail.album ?? []).sorted { lhs, rhs in
            switch (lhs.year, rhs.year) {
            case let (y1?, y2?): return y1 > y2
            case (_?, nil):      return true
            case (nil, _?):      return false
            case (nil, nil):     return lhs.name < rhs.name
            }
        }
        let sample = Array(albums.prefix(Self.backfillMaxAlbumsPerArtist))
        guard !sample.isEmpty else { return [] }

        var collected: [DisplayableSong] = []
        await withTaskGroup(of: [DisplayableSong].self) { group in
            var submitted = 0
            let limit = Self.backfillAlbumConcurrency

            while submitted < min(limit, sample.count) {
                let albumId = sample[submitted].id
                group.addTask { await self.fetchAlbumTracksLightweight(albumId: albumId) }
                submitted += 1
            }

            while let songs = await group.next() {
                collected.append(contentsOf: songs)
                if submitted < sample.count {
                    let albumId = sample[submitted].id
                    group.addTask { await self.fetchAlbumTracksLightweight(albumId: albumId) }
                    submitted += 1
                }
            }
        }

        Logger.library.debug(
            "[ARTIST-TRACKS] backfill sample \(min(sample.count, Self.backfillMaxAlbumsPerArtist))/\(albums.count) albums artistId=\(artistID, privacy: .public) tracks=\(collected.count)"
        )
        return collected
    }

    private func fetchAlbumTracksLightweight(albumId: String) async -> [DisplayableSong] {
        do {
            let detail = try await album(id: albumId)
            return (detail.song ?? []).map { DisplayableSong(from: $0, isDownloaded: false) }
        } catch {
            Logger.library.error("[ARTIST-TRACKS] backfill album \(albumId) failed: \(error, privacy: .public)")
            return []
        }
    }

    // MARK: - Similar artists support

    func topSongs(artist: String, count: Int) async throws -> [DisplayableSong] {
        try await client().getTopSongs(artist: artist, count: count).map { DisplayableSong(from: $0) }
    }

    func getArtistInfo(forArtistID artistID: String, count: Int) async throws -> ArtistInfo {
        if let cached = artistInfoCache[artistID] {
            let satisfied = artistInfoCachedCount[artistID] ?? 0
            let similarHave = cached.similarArtist?.count ?? 0
            // count:0 is bio/MBID only — never let it satisfy a later similar-artists request.
            if count <= 0 || satisfied >= count || similarHave >= count {
                Logger.library.debug("[ARTIST-INFO] cache hit artistId=\(artistID, privacy: .public) similarCount=\(similarHave, privacy: .public)")
                return cached
            }
        }
        Logger.library.debug("[ARTIST-INFO] cache miss — network call artistId=\(artistID, privacy: .public) count=\(count, privacy: .public)")
        let started = Date()
        do {
            let info = try await client().getArtistInfo2(id: artistID, count: count)
            let elapsed = Date().timeIntervalSince(started)
            Logger.library.debug("[ARTIST-INFO] success artistId=\(artistID, privacy: .public) \(String(format: "%.2f", elapsed), privacy: .public)s similarCount=\(info.similarArtist?.count ?? 0, privacy: .public)")
            artistInfoCache[artistID] = info
            artistInfoCachedCount[artistID] = max(count, 0)
            return info
        } catch {
            let elapsed = Date().timeIntervalSince(started)
            Logger.library.warning("[ARTIST-INFO] FAILED after \(String(format: "%.2f", elapsed), privacy: .public)s artistId=\(artistID, privacy: .public): \(error, privacy: .public)")
            throw error
        }
    }

    func getArtistMBID(forArtistID artistID: String) async throws -> String? {
        try await getArtistInfo(forArtistID: artistID, count: 20).musicBrainzId
    }

    func findArtist(byName name: String) async -> ArtistID3? {
        if artistNameIndex == nil {
            if indexBuildTask == nil {
                Logger.library.debug("[FIND-ARTIST] index not built — starting build name=\(name, privacy: .public)")
                indexBuildTask = Task { await self.buildArtistNameIndex() }
            } else {
                Logger.library.debug("[FIND-ARTIST] awaiting in-progress build name=\(name, privacy: .public)")
            }
            _ = await indexBuildTask?.value
            indexBuildTask = nil
        } else {
            Logger.library.debug("[FIND-ARTIST] index ready entries=\(self.artistNameIndex?.count ?? 0, privacy: .public) name=\(name, privacy: .public)")
        }
        let normalized = Self.normalizeArtistName(name)
        if let found = artistNameIndex?[normalized] {
            Logger.library.debug("[FIND-ARTIST] FOUND '\(name, privacy: .public)' → id=\(found.id, privacy: .public)")
            return found
        }
        Logger.library.debug("[FIND-ARTIST] NOT FOUND '\(name, privacy: .public)'")
        return nil
    }

    private func buildArtistNameIndex() async {
        guard let indices = try? await artists() else { return }
        let all = indices.flatMap { $0.artist }
        var index: [String: ArtistID3] = [:]
        index.reserveCapacity(all.count)
        for (i, a) in all.enumerated() {
            let key = Self.normalizeArtistName(a.name)
            if index[key] == nil { index[key] = a }
            if i % 200 == 0 && i > 0 { await Task.yield() }
        }
        artistNameIndex = index
        Logger.library.info("[FIND-ARTIST] index built: \(all.count, privacy: .public) entries")
    }

    /// Applies diacritics-insensitive folding, lowercasing, and whitespace trimming.
    /// `internal` so it is accessible from the test target via `@testable import`.
    nonisolated static func normalizeArtistName(_ name: String) -> String {
        name
            .folding(options: .diacriticInsensitive, locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func offlineSmartShuffle(targetSize: Int) async -> [DisplayableSong] {
        guard let activeServerId = await MainActor.run(body: { serverService.state.activeServer?.id }) else {
            Logger.library.debug("Smart shuffle offline: no active server, returning empty")
            return []
        }

        let songs: [DisplayableSong] = await MainActor.run {
            let context = ModelContext(modelContainer)
            let descriptor = FetchDescriptor<DownloadedTrack>(
                predicate: #Predicate<DownloadedTrack> { $0.serverId == activeServerId }
            )
            let downloads = (try? context.fetch(descriptor)) ?? []
            guard !downloads.isEmpty else {
                Logger.library.debug("Smart shuffle offline: no downloads available")
                return []
            }
            let selected = Array(downloads.shuffled().prefix(targetSize))
            Logger.library.debug("Smart shuffle offline: \(selected.count) tracks from \(downloads.count) downloads")
            return selected.map { DisplayableSong(from: $0) }
        }

        return songs
    }
}
