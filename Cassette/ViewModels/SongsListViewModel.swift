// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import SwiftData
import SwiftSonic

/// One alphabetically grouped block of the Library → Songs list (header letter + its songs).
nonisolated struct SongAlphabetSection: Identifiable, Sendable {
    let letter: String
    let songs: [DisplayableSong]
    /// Index of this section's first song within the flattened `allSongs` order (for playback).
    let startIndex: Int
    var id: String { letter }
}

/// Drives the Library → Songs screen: pages the whole server library, and can swap that source for the
/// starred songs or the tracks downloaded on this device (`SongListFilter`). Sorting / A–Z grouping
/// (`SongSort`) is applied client-side to whichever source is active.
@Observable
@MainActor
final class SongsListViewModel {
    /// Alphabetically grouped sections driving the list headers + jump bar. Empty for "Date Added".
    private(set) var sections: [SongAlphabetSection] = []
    /// Flat, display-ordered list used for playback.
    private(set) var allSongs: [DisplayableSong] = []
    /// Active source (All Songs / Favorites / Downloads).
    private(set) var filter: SongListFilter = .allSongs
    /// Active ordering, mirrored from the caller's persisted preference.
    private(set) var sort: SongSort = .title
    var isLoading = false
    var isLoadingMore = false
    /// True while a Favorites/Downloads source is being swapped in after a filter change.
    var isLoadingFilterSource = false
    var error: UserFacingError?
    /// Only meaningful for `SongListFilter.allSongs` — the other sources are fetched whole.
    var hasMore = true

    /// `true` when the active sort groups into lettered sections (drives the alphabet jump bar).
    var usesAlphabetSections: Bool { sort.groupsAlphabetically }

    private let libraryService: any LibraryServiceProtocol
    /// Needed for the Downloads filter — the local `DownloadedTrack` store is the source of truth.
    private let modelContainer: ModelContainer?
    /// Supplies the active server id for the local downloads lookup.
    private let serverState: ServerState?

    private let pageSize = 500
    private var offset = 0
    private var libraryHasMore = true
    /// Songs of the active filter before sorting (library pages, starred songs, or local downloads).
    private var source: [DisplayableSong] = []
    /// `Song.created` (library/starred) or `DownloadedTrack.downloadedAt` (downloads), keyed by song id.
    private var addedDates: [String: Date] = [:]
    private var rawSongs: [Song] = []
    private var localTracks: [DownloadedTrack] = []
    private var downloadedSongIds: Set<String> = []

    init(
        libraryService: any LibraryServiceProtocol,
        modelContainer: ModelContainer? = nil,
        serverState: ServerState? = nil
    ) {
        self.libraryService = libraryService
        self.modelContainer = modelContainer
        self.serverState = serverState
    }

    // MARK: - Loading

    /// Reloads the active source from its origin (page 0 for the library, a fresh fetch otherwise).
    func load() async {
        guard !isLoading else { return }
        isLoading = true
        error = nil
        refreshLocalTracks()

        switch filter {
        case .allSongs:
            offset = 0
            do {
                let page = try await libraryService.librarySongs(offset: 0, count: pageSize)
                rawSongs = page
                offset = page.count
                libraryHasMore = page.count == pageSize
                addedDates = Self.addedDates(from: page)
                source = page.map { DisplayableSong(from: $0) }
            } catch {
                self.error = UserFacingError.from(error)
            }
        case .favorites:
            await reloadStarredSongs()
        case .downloads:
            applyLocalTrackSource()
        }

        hasMore = filter == .allSongs && libraryHasMore
        rebuild()
        isLoading = false
    }

    func loadMoreIfNeeded() async {
        guard filter == .allSongs, !isLoading, !isLoadingMore, libraryHasMore else { return }
        isLoadingMore = true
        do {
            let page = try await libraryService.librarySongs(offset: offset, count: pageSize)
            if page.isEmpty {
                libraryHasMore = false
            } else {
                var seen = Set(rawSongs.map(\.id))
                for song in page where !seen.contains(song.id) {
                    rawSongs.append(song)
                    seen.insert(song.id)
                }
                offset += page.count
                addedDates.merge(Self.addedDates(from: page)) { _, new in new }
                source = rawSongs.map { DisplayableSong(from: $0) }
                libraryHasMore = page.count == pageSize
                rebuild()
            }
        } catch {
            // Pagination failures are non-fatal; pull-to-refresh retries from the top.
        }
        hasMore = filter == .allSongs && libraryHasMore
        isLoadingMore = false
    }

    // MARK: - Source & ordering

    /// Swaps the list's source. Favorites/Downloads are fetched whole (they are not paginated), so the
    /// alphabet jump bar and the Play/Shuffle header always act on the complete selection.
    func setFilter(_ newFilter: SongListFilter) async {
        guard newFilter != filter else { return }
        filter = newFilter
        error = nil

        switch newFilter {
        case .allSongs:
            // Library pages are already cached — reuse them unless the first load never happened.
            guard !rawSongs.isEmpty else {
                await load()
                return
            }
            addedDates = Self.addedDates(from: rawSongs)
            source = rawSongs.map { DisplayableSong(from: $0) }
            hasMore = libraryHasMore
            rebuild()
        case .favorites:
            isLoadingFilterSource = true
            await reloadStarredSongs()
            hasMore = false
            rebuild()
            isLoadingFilterSource = false
        case .downloads:
            isLoadingFilterSource = true
            refreshLocalTracks()
            applyLocalTrackSource()
            hasMore = false
            rebuild()
            isLoadingFilterSource = false
        }
    }

    /// Re-orders the current source. Synchronous — nothing is refetched.
    func setSort(_ newSort: SongSort) {
        guard newSort != sort else { return }
        sort = newSort
        rebuild()
    }

    private func reloadStarredSongs() async {
        do {
            let songs = try await libraryService.getStarred2().song ?? []
            addedDates = Self.addedDates(from: songs)
            source = songs.map { DisplayableSong(from: $0) }
        } catch {
            self.error = UserFacingError.from(error)
            addedDates = [:]
            source = []
        }
    }

    /// The Downloads source: local tracks carry a `downloadedAt` timestamp that stands in for "date added".
    private func applyLocalTrackSource() {
        addedDates = Dictionary(localTracks.map { ($0.songId, $0.downloadedAt) }, uniquingKeysWith: { first, _ in first })
        source = localTracks.map { DisplayableSong(from: $0) }
    }

    /// Reads the active server's downloaded tracks (metadata only) so the Downloads filter and the
    /// per-row downloaded badge need no network round-trip.
    private func refreshLocalTracks() {
        guard let modelContainer, let serverId = serverState?.activeServer?.id else {
            localTracks = []
            downloadedSongIds = []
            return
        }
        let context = ModelContext(modelContainer)
        let sid = serverId
        let descriptor = FetchDescriptor<DownloadedTrack>(predicate: #Predicate<DownloadedTrack> { $0.serverId == sid })
        localTracks = (try? context.fetch(descriptor)) ?? []
        downloadedSongIds = Set(localTracks.map(\.songId))
    }

    // MARK: - Grouping

    private func rebuild() {
        let ordered = orderedSongs()

        guard sort.groupsAlphabetically else {
            sections = []
            allSongs = ordered
            return
        }

        var byLetter: [String: [DisplayableSong]] = [:]
        for song in ordered {
            byLetter[alphabetFirstLetter(of: sort.groupingKey(for: song)), default: []].append(song)
        }

        var result: [SongAlphabetSection] = []
        var running = 0
        for letter in byLetter.keys.sorted(by: Self.letterOrder) {
            let group = byLetter[letter] ?? []
            result.append(SongAlphabetSection(letter: letter, songs: group, startIndex: running))
            running += group.count
        }
        sections = result
        allSongs = result.flatMap(\.songs)
    }

    /// Applies the active sort to the source songs. The alphabetical sorts also order the array, so
    /// `rebuild()` only has to partition it into sections; "Date Added" sorts newest-first (songs the
    /// server never dated land last) and stays a single flat list.
    private func orderedSongs() -> [DisplayableSong] {
        let songs = source.map { downloadedSongIds.contains($0.id) ? $0.withDownloaded(true) : $0 }
        switch sort {
        case .title:
            return songs.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .artist:
            return songs.sorted { lhs, rhs in
                let left = sort.groupingKey(for: lhs)
                let right = sort.groupingKey(for: rhs)
                let byArtist = left.localizedStandardCompare(right)
                guard byArtist == .orderedSame else { return byArtist == .orderedAscending }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
        case .dateAdded:
            return songs.sorted { (addedDates[$0.id] ?? .distantPast) > (addedDates[$1.id] ?? .distantPast) }
        }
    }

    /// Letters A–Z first (alphabetical), then `#` last — matches `AlphabetJumpBar`'s order.
    private static func letterOrder(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == "#" { return false }
        if rhs == "#" { return true }
        return lhs.compare(rhs, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedAscending
    }

    /// `Song.created` is optional — servers that omit it simply sort last under "Date Added".
    private static func addedDates(from songs: [Song]) -> [String: Date] {
        var result: [String: Date] = [:]
        for song in songs {
            if let created = song.created { result[song.id] = created }
        }
        return result
    }
}
