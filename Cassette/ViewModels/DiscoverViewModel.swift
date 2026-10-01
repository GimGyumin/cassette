// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import SwiftSonic
import OSLog

/// Memory + disk cache so Home paints instantly on cold start.
@MainActor
enum DiscoverSectionsCache {
    private(set) static var recentlyPlayed: [AlbumID3] = []
    private(set) static var mostPlayed: [AlbumID3] = []
    private(set) static var suggestedSelection: [AlbumID3] = []
    private static var loadedAt: Date?
    private static var diskServerId: String?
    private static var didLoadFromDisk = false
    /// Serializes atomic writes/deletes. Detached fire-and-forget mutations could previously
    /// finish out of order, letting an older Home payload overwrite a newer one (or reappear
    /// immediately after the user cleared the cache).
    private static var diskMutationTask: Task<Void, Never>?
    /// Soft TTL for skipping a network refresh; stale disk data still paints the UI.
    private static let ttl: TimeInterval = 90

    nonisolated private struct DiskPayload: Codable, Sendable {
        let serverId: String
        let loadedAt: Date
        let recentlyPlayed: [AlbumID3]
        let mostPlayed: [AlbumID3]
        let suggestedSelection: [AlbumID3]
    }

    static var isFresh: Bool {
        guard let loadedAt else { return false }
        return Date().timeIntervalSince(loadedAt) < ttl
            && hasContent
    }

    static var hasContent: Bool {
        !recentlyPlayed.isEmpty || !mostPlayed.isEmpty || !suggestedSelection.isEmpty
    }

    /// Loads last successful Home shelves from disk (server-scoped). Safe to call repeatedly.
    static func hydrateFromDiskIfNeeded(serverId: String?) async {
        if didLoadFromDisk {
            if let serverId, let diskServerId, serverId != diskServerId {
                clearMemory()
                await loadFromDisk(matching: serverId)
            }
            return
        }
        didLoadFromDisk = true
        await loadFromDisk(matching: serverId)
    }

    static func store(recent: [AlbumID3], frequent: [AlbumID3], suggested: [AlbumID3], serverId: String?) {
        recentlyPlayed = recent
        mostPlayed = frequent
        suggestedSelection = suggested
        loadedAt = Date()
        let sid = serverId ?? diskServerId
        if let sid {
            diskServerId = sid
            let payload = DiskPayload(
                serverId: sid,
                loadedAt: loadedAt ?? Date(),
                recentlyPlayed: recentlyPlayed,
                mostPlayed: mostPlayed,
                suggestedSelection: suggestedSelection
            )
            let previousMutation = diskMutationTask
            diskMutationTask = Task.detached(priority: .utility) {
                if let previousMutation { await previousMutation.value }
                Self.writePayload(payload)
            }
        }
    }

    static func clear() {
        clearMemory()
        didLoadFromDisk = false
        diskServerId = nil
        let previousMutation = diskMutationTask
        diskMutationTask = Task.detached(priority: .utility) {
            if let previousMutation { await previousMutation.value }
            guard let url = Self.fileURL() else { return }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func clearMemory() {
        recentlyPlayed = []
        mostPlayed = []
        suggestedSelection = []
        loadedAt = nil
    }

    private static func loadFromDisk(matching serverId: String?) async {
        // Never hydrate a file while a preceding write/delete is still in progress.
        if let diskMutationTask { await diskMutationTask.value }
        let payload: DiskPayload? = await Task.detached(priority: .utility) {
            Self.readPayload()
        }.value
        guard let payload else { return }
        if let serverId, payload.serverId != serverId { return }
        recentlyPlayed = payload.recentlyPlayed
        mostPlayed = payload.mostPlayed
        suggestedSelection = payload.suggestedSelection
        loadedAt = payload.loadedAt
        diskServerId = payload.serverId
    }

    nonisolated private static func readPayload() -> DiskPayload? {
        guard let url = fileURL(),
              let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(DiskPayload.self, from: data)
        else { return nil }
        return payload
    }

    nonisolated private static func writePayload(_ payload: DiskPayload) {
        guard let url = fileURL(),
              let data = try? JSONEncoder().encode(payload)
        else { return }
        try? data.write(to: url, options: .atomic)
    }

    nonisolated private static func fileURL() -> URL? {
        do {
            let appSupport = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let dir = appSupport.appendingPathComponent("app.cassette", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir.appendingPathComponent("discover-sections-cache.json")
        } catch {
            return nil
        }
    }
}

@Observable
@MainActor
final class DiscoverViewModel {
    private let libraryService: any LibraryServiceProtocol
    private let recommendationService: RecommendationService
    private let personalMixService: PersonalMixService?

    // MARK: - State

    private(set) var recentlyPlayed: [AlbumID3] = []
    private(set) var mostPlayed: [AlbumID3] = []
    private(set) var suggestedSelection: [AlbumID3] = []
    private(set) var personalMixes: [PersonalMix] = []
    private(set) var isLoading: Bool = false
    private(set) var loadError: Error?
    private(set) var freshReleases: [AlbumRecommendation] = []
    private(set) var isLoadingFreshReleases: Bool = false
    private(set) var spatialAlbums: [AlbumID3] = []
    private(set) var isLoadingSpatialAlbums: Bool = false
    private var deferredPersonalMixTask: Task<Void, Never>?

    init(
        libraryService: any LibraryServiceProtocol,
        recommendationService: RecommendationService,
        personalMixService: PersonalMixService? = nil,
        serverId: String? = nil
    ) {
        self.libraryService = libraryService
        self.recommendationService = recommendationService
        self.personalMixService = personalMixService
        // Disk hydrate is async — apply on the next turn so init stays synchronous.
        Task { @MainActor in
            await DiscoverSectionsCache.hydrateFromDiskIfNeeded(serverId: serverId)
            if DiscoverSectionsCache.hasContent {
                self.applyCache()
            }
        }
    }

    isolated deinit {
        deferredPersonalMixTask?.cancel()
    }

    // MARK: - Derived state

    /// True when the initial fetch is in progress and we have nothing to show yet.
    var isInitialLoading: Bool {
        isLoading && recentlyPlayed.isEmpty && mostPlayed.isEmpty && suggestedSelection.isEmpty
    }

    /// True when load failed and we have nothing to show.
    var isErrorState: Bool {
        loadError != nil && recentlyPlayed.isEmpty && mostPlayed.isEmpty && suggestedSelection.isEmpty
    }

    // MARK: - Loading

    /// Lightweight Home dashboard — paint from cache immediately, then refresh.
    func loadHomeDashboard(forceRefresh: Bool = false, serverId: String? = nil) async {
        await DiscoverSectionsCache.hydrateFromDiskIfNeeded(serverId: serverId)

        if !forceRefresh, DiscoverSectionsCache.hasContent {
            applyCache()
            AppBootGate.markHomeReady()
            if DiscoverSectionsCache.isFresh {
                // Shelves are fresh — don't storm getTopSongs alongside Home cover decode.
                scheduleDeferredPersonalMixes(serverId: serverId)
                return
            }
            // Stale disk/memory content is already on screen — soft-refresh below.
        } else if !forceRefresh, !recentlyPlayed.isEmpty {
            fillMissingShelvesFromCache()
            AppBootGate.markHomeReady()
            scheduleDeferredPersonalMixes(serverId: serverId)
            return
        }

        let hadContent = !recentlyPlayed.isEmpty || !mostPlayed.isEmpty || !suggestedSelection.isEmpty
        if !hadContent {
            isLoading = true
        }

        do {
            // One request first so UI can paint; unlock other tabs before the remaining shelves.
            let recent = try await libraryService.recentlyPlayedAlbums(size: 16)
            recentlyPlayed = recent
            loadError = nil
            isLoading = false
            AppBootGate.markHomeReady()

            async let frequentTask: [AlbumID3] = {
                do {
                    return try await libraryService.mostPlayedAlbums(size: 16)
                } catch {
                    if UserFacingError.isCancellation(error) { return [] }
                    Logger.discover.error("Failed to load Frequently Played: \(error, privacy: .public)")
                    return []
                }
            }()
            async let suggestedTask: [AlbumID3] = {
                do {
                    return try await libraryService.randomAlbums(size: 16)
                } catch {
                    if UserFacingError.isCancellation(error) { return [] }
                    Logger.discover.error("Failed to load Suggested Selection: \(error, privacy: .public)")
                    return []
                }
            }()
            let frequent = await frequentTask
            let suggested = await suggestedTask
            // Assign remaining shelves together (one NavigationLink registration wave).
            mostPlayed = frequent
            suggestedSelection = suggested
            DiscoverSectionsCache.store(
                recent: recent,
                frequent: frequent,
                suggested: suggested,
                serverId: serverId
            )
            // Mixes are the heaviest network burst — defer them off the cold-start critical path.
            scheduleDeferredPersonalMixes(serverId: serverId)
        } catch is CancellationError {
            isLoading = false
            AppBootGate.markHomeReady()
        } catch {
            if UserFacingError.isCancellation(error) {
                isLoading = false
                AppBootGate.markHomeReady()
                return
            }
            if !hadContent {
                loadError = error
            }
            isLoading = false
            AppBootGate.markHomeReady()
            Logger.discover.error("Failed to load Home dashboard: \(error, privacy: .public)")
        }
    }

    func load(forceRefresh: Bool = false, serverId: String? = nil) async {
        await DiscoverSectionsCache.hydrateFromDiskIfNeeded(serverId: serverId)

        if !forceRefresh, !recentlyPlayed.isEmpty, !mostPlayed.isEmpty {
            fillMissingShelvesFromCache()
            return
        }
        if !forceRefresh, DiscoverSectionsCache.hasContent {
            applyCache()
            if DiscoverSectionsCache.isFresh, !recentlyPlayed.isEmpty, !mostPlayed.isEmpty { return }
        }

        isLoading = true
        defer { isLoading = false }

        do {
            async let recent = libraryService.recentlyPlayedAlbums(size: 35)
            async let frequent = libraryService.mostPlayedAlbums(size: 35)
            async let suggested = libraryService.randomAlbums(size: 35)
            let (recentResult, frequentResult, suggestedResult) = try await (recent, frequent, suggested)
            // One observation turn — avoids NavigationRequestObserver multi-update spam when
            // three shelves of NavigationLinks appear across consecutive frames.
            recentlyPlayed = recentResult
            mostPlayed = frequentResult
            suggestedSelection = suggestedResult
            DiscoverSectionsCache.store(
                recent: recentResult,
                frequent: frequentResult,
                suggested: suggestedResult,
                serverId: serverId
            )
            self.loadError = nil
        } catch {
            if UserFacingError.isCancellation(error) { return }
            self.loadError = error
            Logger.discover.error("Failed to load Discover sections: \(error, privacy: .public)")
        }
    }

    func loadFreshReleases() async {
        isLoadingFreshReleases = true
        defer { isLoadingFreshReleases = false }
        do {
            let fetched = try await recommendationService.freshReleases(limit: 10, daysWindow: 7)
            freshReleases = fetched.sorted {
                ($0.releaseDate ?? .distantPast) > ($1.releaseDate ?? .distantPast)
            }
        } catch {
            Logger.discover.error("Failed to load fresh releases: \(error, privacy: .public)")
        }
    }

    /// Pages through metadata so rare multichannel albums are not lost in a random sample.
    func loadSpatialAlbums(force: Bool = false) async {
        guard !isLoadingSpatialAlbums else { return }
        if !force, !spatialAlbums.isEmpty { return }
        isLoadingSpatialAlbums = true
        defer { isLoadingSpatialAlbums = false }
        do {
            var seen = Set<String>()
            var found: [AlbumID3] = []
            var offset = 0
            var pageStarts = Set<String>()
            while found.count < 24 {
                try Task.checkCancellation()
                let page = try await libraryService.librarySongs(offset: offset, count: 500)
                let legacyFallback = page.isEmpty && offset == 0
                let songs = legacyFallback ? try await libraryService.randomSongs(size: 500) : page
                guard let first = songs.first, pageStarts.insert(first.id).inserted else { break }
                offset += songs.count
                for song in songs {
                    let display = DisplayableSong(from: song)
                    guard AudioQualityClassifier.isSpatialOrMultichannel(display) else { continue }
                    guard let albumId = song.albumId, !albumId.isEmpty, seen.insert(albumId).inserted else { continue }
                    found.append(
                        AlbumID3(
                            id: albumId,
                            name: song.album ?? song.title,
                            songCount: 1,
                            duration: song.duration ?? 0,
                            artist: song.artist,
                            artistId: song.artistId,
                            coverArt: song.coverArt,
                            year: song.year,
                            genre: song.genre
                        )
                    )
                    if found.count >= 24 { break }
                }
                spatialAlbums = found
                if legacyFallback { break }
            }
            spatialAlbums = found
        } catch {
            if UserFacingError.isCancellation(error) { return }
            Logger.discover.error("Failed to load Spatial Audio albums: \(error, privacy: .public)")
        }
    }

    private func scheduleDeferredPersonalMixes(serverId: String?) {
        guard deferredPersonalMixTask == nil else { return }
        deferredPersonalMixTask = Task(priority: .utility) { @MainActor [weak self] in
            defer {
                self?.deferredPersonalMixTask = nil
            }
            // `try?` keeps the closure non-throwing: sleep only throws on cancellation
            // (or an unlikely clock error), and the guard below handles cancellation.
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await self?.loadPersonalMixes(serverId: serverId, forceRefresh: false, progressive: true)
        }
    }

    private func loadPersonalMixes(serverId: String?, forceRefresh: Bool, progressive: Bool = false) async {
        guard let personalMixService else { return }
        if progressive {
            if forceRefresh || personalMixes.isEmpty {
                personalMixes = await personalMixService.mixes(serverId: serverId, forceRefresh: forceRefresh, limit: 1)
            }
            personalMixes = await personalMixService.mixes(serverId: serverId, forceRefresh: false)
            return
        }
        if !forceRefresh, !personalMixes.isEmpty { return }
        personalMixes = await personalMixService.mixes(serverId: serverId, forceRefresh: forceRefresh)
    }

    private func applyCache() {
        recentlyPlayed = DiscoverSectionsCache.recentlyPlayed
        mostPlayed = DiscoverSectionsCache.mostPlayed
        suggestedSelection = DiscoverSectionsCache.suggestedSelection
    }

    private func fillMissingShelvesFromCache() {
        guard DiscoverSectionsCache.hasContent else { return }
        if mostPlayed.isEmpty {
            mostPlayed = DiscoverSectionsCache.mostPlayed
        }
        if suggestedSelection.isEmpty {
            suggestedSelection = DiscoverSectionsCache.suggestedSelection
        }
    }
}
