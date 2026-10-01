// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.

import Foundation
import SwiftSonic

@Observable
@MainActor
final class SearchViewModel {
    static let searchDebounce: Duration = .milliseconds(300)

    var searchResults: SearchResult3?
    var isSearching = false
    var isIndexing: Bool { !downloadsOnly && (libraryIndex?.isIndexing ?? false) }
    var searchError: UserFacingError?
    private(set) var isLoadingMore = false
    private(set) var localHits: LibraryIndexService.LocalHits = .init(artists: [], albums: [], playlists: [])
    private(set) var localSongs: [DisplayableSong] = []
    private(set) var isLocalOnly = false

    private let libraryService: any LibraryServiceProtocol
    private weak var libraryIndex: LibraryIndexService?
    private let downloads: (@MainActor (String) -> [DisplayableSong])?
    private var requestID: UInt64 = 0
    private var activeQuery = ""
    private var downloadsOnly = false
    private var nextPage = SearchPageRequest()

    init(
        libraryService: any LibraryServiceProtocol,
        libraryIndex: LibraryIndexService? = nil,
        downloads: (@MainActor (String) -> [DisplayableSong])? = nil
    ) {
        self.libraryService = libraryService
        self.libraryIndex = libraryIndex
        self.downloads = downloads
    }

    func prepareLocalIndex() {
        libraryIndex?.ensureIndexed(using: libraryService)
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
        localHits = .init(artists: [], albums: [], playlists: [])
        localSongs = []
        isLocalOnly = !serverReachable || downloadsOnly
        guard !trimmed.isEmpty else {
            isLocalOnly = false
            return
        }
        defer { if token == requestID { isSearching = false } }

        do {
            // Debounce local metadata work as well as network requests.
            try await Task.sleep(for: Self.searchDebounce)
            guard token == requestID else { return }
            refreshLocalResults()
            // An indexed library is the default search source. Typing never performs catalog requests.
            if let libraryIndex, !downloadsOnly {
                libraryIndex.ensureIndexed(using: libraryService)
                return
            }
            guard !isLocalOnly else { return }
            libraryIndex?.ensureIndexed(using: libraryService)
            let results = try await libraryService.search(trimmed, page: nextPage)
            try Task.checkCancellation()
            guard token == requestID else { return }
            append(results, request: nextPage)
            refreshLocalResults(includeDownloads: false)
        } catch where Self.isCancellation(error) {
        } catch {
            guard token == requestID else { return }
            searchError = UserFacingError.from(error)
        }
    }

    /// Index completion refreshes only local hits, without restarting the server request.
    func refreshLocalResults(includeDownloads: Bool = true) {
        guard !activeQuery.isEmpty else { return }
        if includeDownloads { localSongs = downloads?(activeQuery) ?? [] }
        localHits = downloadsOnly ? .init(artists: [], albums: [], playlists: [])
            : libraryIndex?.search(query: activeQuery, limit: .max)
                ?? .init(artists: [], albums: [], playlists: [])
    }

    func canLoadMore(_ category: SearchCategory) -> Bool {
        guard libraryIndex == nil, !isLocalOnly, searchResults != nil else { return false }
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
        let remote = (searchResults?.album ?? []).map {
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
        let names = songs.map(\.title) + artists.map(\.name) + albums.map(\.name)
        let matches = names.filter { $0.localizedStandardContains(activeQuery) }
        return Array(Self.unique([activeQuery] + matches, excluding: [], id: \.self).prefix(3))
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
