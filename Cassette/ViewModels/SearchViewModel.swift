// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.

import Foundation
import SwiftSonic

@Observable
@MainActor
final class SearchViewModel {
    static let searchDebounce: Duration = .milliseconds(300)
    static let localSearchDebounce: Duration = .milliseconds(80)

    var searchResults: SearchResult3?
    var isSearching = false
    var isIndexing: Bool { !downloadsOnly && (libraryIndex?.isPreparing ?? false) }
    var searchError: UserFacingError?
    private(set) var isLoadingMore = false
    private(set) var localHits: LibraryIndexService.LocalHits = .init(artists: [], albums: [], playlists: [])
    private(set) var localSongs: [DisplayableSong] = []
    private(set) var isLocalOnly = false
    private(set) var rankedItems: [SearchResultItem] = []
    private var presentationGeneration: UInt64 = 0

    private let libraryService: any LibraryServiceProtocol
    private weak var libraryIndex: LibraryIndexService?
    private let downloads: (@MainActor (String) async -> [DisplayableSong])?
    private var requestID: UInt64 = 0
    private var activeQuery = ""
    private var downloadsOnly = false
    private var nextPage = SearchPageRequest()
    private var localResultLimit = 80
    private var usingRemoteSearch = false
    private var localHasMore: Set<SearchCategory> = []

    init(
        libraryService: any LibraryServiceProtocol,
        libraryIndex: LibraryIndexService? = nil,
        downloads: (@MainActor (String) async -> [DisplayableSong])? = nil
    ) {
        self.libraryService = libraryService
        self.libraryIndex = libraryIndex
        self.downloads = downloads
    }

    func prepareLocalIndex() {
        libraryIndex?.ensureIndexed(using: libraryService)
    }

    func retryLocalIndexIfNeeded() async {
        guard let libraryIndex, libraryIndex.lastError != nil else { return }
        await libraryIndex.rebuildAndWait(using: libraryService)
    }

    func search(query: String, serverReachable: Bool = true, downloadsOnly: Bool = false) async {
        requestID &+= 1
        let token = requestID
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        activeQuery = trimmed
        self.downloadsOnly = downloadsOnly
        searchResults = nil
        searchError = nil
        isSearching = !trimmed.isEmpty
        isLoadingMore = false
        nextPage = SearchPageRequest()
        localResultLimit = 80
        usingRemoteSearch = false
        localHasMore = []
        localHits = .init(artists: [], albums: [], playlists: [])
        localSongs = []
        rankedItems = []
        isLocalOnly = !serverReachable || downloadsOnly
        guard !trimmed.isEmpty else {
            isLocalOnly = false
            return
        }
        defer { if token == requestID { isSearching = false } }

        do {
            // Local metadata responds quickly; keep a longer quiet period for HTTP.
            try await Task.sleep(for: Self.localSearchDebounce)
            guard token == requestID else { return }
            await refreshLocalResults()
            try Task.checkCancellation()
            guard token == requestID else { return }
            // Keep first-run search usable while the complete local catalog is being built.
            // Subsequent queries use the index once ready; offline queries keep local results.
            if let libraryIndex, !downloadsOnly {
                if libraryIndex.lastError == nil {
                    if libraryIndex.hasUsableIndex { return }
                    libraryIndex.ensureIndexed(using: libraryService)
                }
                if isLocalOnly {
                    if libraryIndex.lastError != nil { searchError = .searchIndexUnavailable }
                    return
                }
            }
            guard !isLocalOnly else { return }
            try await Task.sleep(for: Self.searchDebounce - Self.localSearchDebounce)
            guard token == requestID else { return }
            usingRemoteSearch = true
            let results = try await libraryService.search(trimmed, page: nextPage)
            try Task.checkCancellation()
            guard token == requestID else { return }
            append(results, request: nextPage)
            await updateResultOrder()
        } catch where Self.isCancellation(error) {
        } catch {
            guard token == requestID else { return }
            searchError = UserFacingError.from(error)
        }
    }

    /// Index completion refreshes only local hits, without restarting the server request.
    func refreshLocalResults(includeDownloads: Bool = true) async {
        guard !activeQuery.isEmpty else { return }
        let token = requestID
        let query = activeQuery
        async let downloaded = includeDownloads ? downloads?(query) : nil
        let hits = downloadsOnly ? nil : await libraryIndex?.searchInBackground(query: query, limit: localResultLimit + 1)
        guard token == requestID, !Task.isCancelled else { return }
        localHasMore = []
        if let hits {
            if hits.artists.count > localResultLimit { localHasMore.insert(.artists) }
            if hits.albums.count > localResultLimit { localHasMore.insert(.albums) }
            if hits.playlists.count > localResultLimit { localHasMore.insert(.playlists) }
            if hits.songs.count > localResultLimit { localHasMore.insert(.songs) }
            localHits = .init(artists: Array(hits.artists.prefix(localResultLimit)),
                              albums: Array(hits.albums.prefix(localResultLimit)),
                              playlists: Array(hits.playlists.prefix(localResultLimit)),
                              songs: Array(hits.songs.prefix(localResultLimit)))
        } else { localHits = .init(artists: [], albums: [], playlists: []) }
        // Publish indexed hits before a potentially large SwiftData download scan finishes.
        await updateResultOrder()
        let downloadedSongs = await downloaded
        guard token == requestID, !Task.isCancelled else { return }
        if let downloadedSongs {
            let needsRefresh = !localSongs.isEmpty || !downloadedSongs.isEmpty
            localSongs = downloadedSongs
            if needsRefresh { await updateResultOrder() }
        }
    }

    private func updateResultOrder() async {
        presentationGeneration &+= 1
        let generation = presentationGeneration
        let token = requestID
        let items = songs.map(SearchResultItem.song) + artists.map(SearchResultItem.artist)
            + albums.map(SearchResultItem.album) + localHits.playlists.map(SearchResultItem.playlist)
        let query = activeQuery
        let locale = AppUILanguage.locale
        let worker = Task.detached(priority: .userInitiated) {
            SearchResultItem.ranked(items, query: query, locale: locale)
        }
        let rows = await withTaskCancellationHandler {
            await worker.value
        } onCancel: { worker.cancel() }
        guard token == requestID, generation == presentationGeneration, !Task.isCancelled else { return }
        rankedItems = rows
    }

    func canLoadMore(_ category: SearchCategory) -> Bool {
        if !usingRemoteSearch, libraryIndex?.hasUsableIndex == true, !downloadsOnly {
            return category == .all ? !localHasMore.isEmpty : localHasMore.contains(category)
        }
        guard usingRemoteSearch, !isLocalOnly, searchResults != nil else { return false }
        switch category {
        case .all: return nextPage.artistCount > 0 || nextPage.albumCount > 0 || nextPage.songCount > 0
        case .artists: return nextPage.artistCount > 0
        case .albums: return nextPage.albumCount > 0
        case .songs: return nextPage.songCount > 0
        case .playlists: return false
        }
    }

    func loadMore(category: SearchCategory = .all) async {
        guard !isSearching, !isLoadingMore, canLoadMore(category) else { return }
        if !usingRemoteSearch {
            isLoadingMore = true
            defer { isLoadingMore = false }
            localResultLimit += 80
            await refreshLocalResults()
            return
        }
        let token = requestID
        var request = nextPage
        if category != .all {
            if category != .artists { request.artistCount = 0 }
            if category != .albums { request.albumCount = 0 }
            if category != .songs { request.songCount = 0 }
        }
        isLoadingMore = true
        searchError = nil
        defer { if token == requestID { isLoadingMore = false } }
        do {
            let page = try await libraryService.search(activeQuery, page: request)
            try Task.checkCancellation()
            guard token == requestID else { return }
            append(page, request: request)
            await updateResultOrder()
        } catch where Self.isCancellation(error) {
        } catch {
            guard token == requestID else { return }
            searchError = UserFacingError.from(error)
        }
    }

    private func append(_ page: SearchResult3, request: SearchPageRequest) {
        var artists = searchResults?.artist ?? []
        var albums = searchResults?.album ?? []
        var songs = searchResults?.song ?? []
        if request.artistCount > 0 {
            let received = page.artist ?? []
            let additions = Self.unique(received, excluding: artists.map(\.id), id: \.id)
            nextPage.artistOffset += received.count
            if additions.isEmpty { nextPage.artistCount = 0 }
            artists += additions
        }
        if request.albumCount > 0 {
            let received = page.album ?? []
            let additions = Self.unique(received, excluding: albums.map(\.id), id: \.id)
            nextPage.albumOffset += received.count
            if additions.isEmpty { nextPage.albumCount = 0 }
            albums += additions
        }
        if request.songCount > 0 {
            let received = page.song ?? []
            let additions = Self.unique(received, excluding: songs.map(\.id), id: \.id)
            nextPage.songOffset += received.count
            if additions.isEmpty { nextPage.songCount = 0 }
            songs += additions
        }
        // A short page needn't mean EOF: some servers cap counts below our requested size.
        // Empty/repeated pages stop paging, including servers that ignore offsets.
        searchResults = SearchResult3(artist: artists, album: albums, song: songs)
    }

    var artists: [LibraryIndexService.IndexedArtist] {
        let remote = (searchResults?.artist ?? []).map {
            LibraryIndexService.IndexedArtist(id: $0.id, name: $0.name, coverArtId: $0.coverArt)
        }
        return remote + Self.unique(localHits.artists, excluding: remote.map(\.id), id: \.id)
    }

    var albums: [LibraryIndexService.IndexedAlbum] {
        let raw = searchResults?.album ?? []
        let remote = (libraryIndex?.presentedAlbums(raw) ?? AtmosAlbumPolicy.presented(raw)).map {
            LibraryIndexService.IndexedAlbum(id: $0.id, name: $0.name, artist: $0.artist, coverArtId: $0.coverArt)
        }
        return remote + Self.unique(localHits.albums, excluding: remote.map(\.id), id: \.id)
    }

    var songs: [DisplayableSong] {
        let downloadedIDs = Set(localSongs.map(\.id))
        let remote = (searchResults?.song ?? []).map {
            DisplayableSong(from: $0, isDownloaded: downloadedIDs.contains($0.id))
        }
        let indexed = Self.unique(localHits.songs, excluding: remote.map(\.id), id: \.id)
            .map { $0.withDownloaded(downloadedIDs.contains($0.id)) }
        return remote + indexed + Self.unique(localSongs, excluding: remote.map(\.id) + indexed.map(\.id), id: \.id)
    }

    var suggestions: [String] {
        guard !activeQuery.isEmpty else { return [] }
        var result = [activeQuery]
        for item in rankedItems {
            let name = item.title
            if !result.contains(name), name.localizedStandardContains(activeQuery) { result.append(name) }
            if result.count == 3 { break }
        }
        return result
    }

    private static func unique<T>(_ values: [T], excluding ids: [String], id: KeyPath<T, String>) -> [T] {
        var seen = Set(ids)
        return values.filter { seen.insert($0[keyPath: id]).inserted }
    }

    private static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        if let sse = error as? SwiftSonicError, case .network(let urlError) = sse, urlError.code == .cancelled { return true }
        return false
    }
}
