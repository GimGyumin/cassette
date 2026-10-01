// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Testing
import Foundation
import SwiftSonic
@testable import Cassette

// MARK: - Counting stub

/// Records `search` calls and replays a configurable outcome.
/// Every other endpoint is unused by SearchViewModel and throws.
/// @MainActor (not an actor): the app module compiles with default MainActor
/// isolation, so its unannotated service protocols are MainActor-isolated.
@MainActor
final class SearchLibraryStub: LibraryServiceProtocol {
    enum Behavior {
        case succeed
        case fail(any Error)
    }

    func song(id: String) async throws -> Song { throw URLError(.unknown) }
    private(set) var searchCalls: [String] = []
    var behavior: Behavior = .succeed

    var pageHandler: ((String, SearchPageRequest) async throws -> SearchResult3)?
    func search(_ query: String, page: SearchPageRequest) async throws -> SearchResult3 {
        if let pageHandler { return try await pageHandler(query, page) }
        return try await search(query)
    }

    func search(_ query: String) async throws -> SearchResult3 {
        searchCalls.append(query)
        switch behavior {
        case .succeed:
            // SearchResult3 is Decodable-only; all fields are optional so "{}" decodes.
            return try JSONDecoder().decode(SearchResult3.self, from: Data("{}".utf8))
        case .fail(let error):
            throw error
        }
    }

    var indexedPlaylists: [Playlist] = []
    var indexedSongs: [Song] = []
    var songPageCap = 20
    private(set) var songOffsets: [Int] = []
    func librarySongs(offset: Int, count: Int) async throws -> [Song] {
        songOffsets.append(offset)
        return Array(indexedSongs.dropFirst(offset).prefix(min(count, songPageCap)))
    }
    func artists() async throws -> [ArtistIndex] { [] }
    func artist(id: String) async throws -> ArtistID3 { throw URLError(.unknown) }
    func album(id: String) async throws -> AlbumID3 { throw URLError(.unknown) }
    func fetchAllTracks(forArtistID artistID: String) async throws -> [DisplayableSong] { throw URLError(.unknown) }
    func playlists() async throws -> [Playlist] { indexedPlaylists }
    func playlist(id: String) async throws -> PlaylistWithSongs { throw URLError(.unknown) }
    var coverURL: URL?
    private(set) var coverSizes: [Int?] = []
    func coverArtURL(id: String, size: Int?) async -> URL? {
        coverSizes.append(size)
        return coverURL
    }
    func streamURL(songId: String) async -> URL? { nil }
    func star(songIds: [String], albumIds: [String], artistIds: [String]) async throws { throw URLError(.unknown) }
    func unstar(songIds: [String], albumIds: [String], artistIds: [String]) async throws { throw URLError(.unknown) }
    func getStarred2() async throws -> Starred2 { throw URLError(.unknown) }
    func recentlyAddedAlbums(size: Int) async throws -> [AlbumID3] { throw URLError(.unknown) }
    func allAlbums() async throws -> [AlbumID3] { [] }
    func scrobble(songId: String, submission: Bool) async {}
    func recentlyPlayedAlbums(size: Int) async throws -> [AlbumID3] { throw URLError(.unknown) }
    func mostPlayedAlbums(size: Int) async throws -> [AlbumID3] { throw URLError(.unknown) }
    func randomSongs(size: Int) async throws -> [Song] { throw URLError(.unknown) }
    func smartShuffleQueue(targetSize: Int) async throws -> [DisplayableSong] { throw URLError(.unknown) }
    func similarBackfillQueue(targetSize: Int, excludedIds: Set<String>) async throws -> [DisplayableSong] { throw URLError(.unknown) }
    func savePlayQueue(songIds: [String], currentIndex: Int, positionSeconds: Double) async throws { throw URLError(.unknown) }
    func getPlayQueue() async throws -> SavedPlayQueue? { throw URLError(.unknown) }
    func getArtistInfo(forArtistID artistID: String, count: Int) async throws -> ArtistInfo { throw URLError(.unknown) }
    func getArtistMBID(forArtistID artistID: String) async throws -> String? { nil }
    func findArtist(byName name: String) async -> ArtistID3? { nil }
    func topSongs(artist: String, count: Int) async throws -> [DisplayableSong] { [] }
}

// MARK: - Tests

@Suite("SearchViewModel — debounce & cancellation")
@MainActor
struct SearchViewModelDebounceTests {

    @Test("rapid query changes call the service once, with the final query")
    func rapidTypingCoalescesToFinalQuery() async throws {
        let stub = SearchLibraryStub()
        let vm = SearchViewModel(libraryService: stub)

        // Emulate SwiftUI's .task(id:) contract: each keystroke cancels the
        // previous call. Cancellation lands during the debounce sleep, well
        // within the quiet period — no wall-clock dependence.
        for partial in ["c", "ca", "cas", "cass"] {
            let superseded = Task { await vm.search(query: partial) }
            superseded.cancel()
            await superseded.value
        }
        await vm.search(query: "cassette")

        #expect(stub.searchCalls == ["cassette"])
        #expect(vm.searchError == nil)
        #expect(vm.isSearching == false)
        #expect(vm.searchResults != nil)
    }

    @Test("empty or whitespace query clears state without any request")
    func emptyQueryClearsWithoutRequest() async throws {
        let stub = SearchLibraryStub()
        let vm = SearchViewModel(libraryService: stub)
        vm.searchResults = try JSONDecoder().decode(SearchResult3.self, from: Data("{}".utf8))
        vm.searchError = .unexpected
        vm.isSearching = true

        await vm.search(query: "   ")

        #expect(vm.searchResults == nil)
        #expect(vm.searchError == nil)
        #expect(vm.isSearching == false)
        #expect(stub.searchCalls.isEmpty)
    }

    @Test("superseded in-flight request is swallowed silently")
    func cancelledRequestIsSilent() async throws {
        let cancellations: [any Error] = [
            CancellationError(),
            URLError(.cancelled),
            SwiftSonicError.network(URLError(.cancelled)),
        ]
        for error in cancellations {
            let stub = SearchLibraryStub()
            stub.behavior = .fail(error)
            let vm = SearchViewModel(libraryService: stub)

            await vm.search(query: "cassette")

            #expect(vm.searchError == nil, "\(error) must not surface to the UI")
            #expect(vm.isSearching == false)
        }
    }

    @Test("a real failure still surfaces as a user-facing error")
    func realErrorSurfaces() async throws {
        let stub = SearchLibraryStub()
        stub.behavior = .fail(URLError(.timedOut))
        let vm = SearchViewModel(libraryService: stub)

        await vm.search(query: "cassette")

        #expect(vm.searchError != nil)
        #expect(vm.isSearching == false)
    }
}

@Suite("Search — paging and stale responses")
@MainActor
struct SearchPaginationTests {
    private func songs(_ range: Range<Int>) -> SearchResult3 {
        SearchResult3(song: range.map { DisplayableSong(id: "song-\($0)", title: "Inst. \($0)").asSong() })
    }

    @Test("indexed playlists survive server results and have no twenty-item cap")
    func keepsAllLocalPlaylists() async throws {
        let stub = SearchLibraryStub()
        let payload = (0..<25).map { ["id": "playlist-\($0)", "name": "Inst. \($0)", "songCount": 1, "duration": 60] as [String: Any] }
        stub.indexedPlaylists = try JSONDecoder().decode([Playlist].self, from: JSONSerialization.data(withJSONObject: payload))
        stub.indexedSongs = songs(0..<1).song ?? []
        let index = LibraryIndexService()
        await index.rebuildAndWait(using: stub)
        let vm = SearchViewModel(libraryService: stub, libraryIndex: index)
        await vm.search(query: "inst")
        #expect(vm.songs.count == 1)
        #expect(vm.localHits.playlists.count == 25)
    }

    @Test("server cap below requested size does not truncate at twenty songs")
    func followsIndependentOffsets() async {
        let stub = SearchLibraryStub()
        var requests: [SearchPageRequest] = []
        stub.pageHandler = { _, page in
            requests.append(page)
            return self.songs(page.songOffset..<min(page.songOffset + 20, 45))
        }
        let vm = SearchViewModel(libraryService: stub)
        await vm.search(query: "inst")
        await vm.loadMore(category: .songs)
        await vm.loadMore(category: .songs)
        await vm.loadMore(category: .songs)
        #expect(vm.songs.count == 45)
        #expect(requests.map(\.songOffset) == [0, 20, 40, 45])
        #expect(requests.dropFirst().allSatisfy { $0.artistCount == 0 && $0.albumCount == 0 })
        #expect(!vm.canLoadMore(.songs))
    }

    @Test("overlapping pages deduplicate; a repeated page stops an offset-ignoring server")
    func repeatedPagesTerminate() async {
        let stub = SearchLibraryStub()
        stub.pageHandler = { _, page in self.songs(page.songOffset == 0 ? 0..<20 : 10..<30) }
        let vm = SearchViewModel(libraryService: stub)
        await vm.search(query: "inst")
        await vm.loadMore()
        #expect(vm.songs.count == 30)
        await vm.loadMore()
        #expect(vm.songs.count == 30)
        #expect(!vm.canLoadMore(.all))
    }

    @Test("an old response cannot restore results after the query is cleared")
    func staleResponseDoesNotWin() async {
        let stub = SearchLibraryStub()
        var continuation: CheckedContinuation<SearchResult3, Never>?
        stub.pageHandler = { _, _ in
            await withCheckedContinuation { continuation = $0 }
        }
        let vm = SearchViewModel(libraryService: stub)
        let request = Task { await vm.search(query: "old") }
        while continuation == nil { await Task.yield() }
        await vm.search(query: "")
        continuation?.resume(returning: songs(0..<20))
        await request.value
        #expect(vm.searchResults == nil)
        #expect(!vm.isSearching)
        #expect(vm.songs.isEmpty)
    }

    @Test("artists with no albumCount stay visible")
    func unknownAlbumCountIsNotFiltered() async throws {
        let artist = try JSONDecoder().decode(ArtistID3.self, from: Data(#"{"id":"artist","name":"Instrumental"}"#.utf8))
        let stub = SearchLibraryStub()
        stub.pageHandler = { _, _ in SearchResult3(artist: [artist]) }
        let vm = SearchViewModel(libraryService: stub)
        await vm.search(query: "inst")
        #expect(vm.artists.map(\.id) == ["artist"])
    }

    @Test("downloads scope makes no catalog request and preserves local songs")
    func downloadsAreLocal() async {
        let stub = SearchLibraryStub()
        let vm = SearchViewModel(libraryService: stub, downloads: { _ in
            [DisplayableSong(id: "offline", title: "Instrumental", isDownloaded: true)]
        })
        await vm.search(query: "inst", downloadsOnly: true)
        #expect(stub.searchCalls.isEmpty)
        #expect(vm.songs.map(\.id) == ["offline"])
        #expect(!vm.canLoadMore(.all))
    }

    @Test("failed next page preserves existing results and can be retried at the same offset")
    func nextPageRetry() async {
        let stub = SearchLibraryStub()
        var shouldFail = true
        stub.pageHandler = { _, page in
            if page.songOffset > 0 && shouldFail { throw URLError(.timedOut) }
            return self.songs(page.songOffset..<(page.songOffset + 20))
        }
        let vm = SearchViewModel(libraryService: stub)
        await vm.search(query: "inst")
        await vm.loadMore(category: .songs)
        #expect(vm.songs.count == 20)
        #expect(vm.searchError != nil)
        shouldFail = false
        await vm.loadMore(category: .songs)
        #expect(vm.songs.count == 40)
        #expect(vm.searchError == nil)
    }
}


@Suite("Persistent library search index")
@MainActor
struct LibrarySearchIndexTests {
    @Test func indexesAllShortPagesAndSearchDoesNotContactServer() async {
        let library = SearchLibraryStub()
        library.indexedSongs = (0..<65).map { DisplayableSong(id: "song-\($0)", title: "Instrumental \($0)").asSong() }
        let index = LibraryIndexService()
        await index.rebuildAndWait(using: library)
        #expect(library.songOffsets == [0, 20, 40, 60, 65])
        let vm = SearchViewModel(libraryService: library, libraryIndex: index)
        await vm.search(query: "instrumental")
        #expect(vm.songs.count == 65)
        #expect(library.searchCalls.isEmpty)
        #expect(!vm.canLoadMore(.songs))
    }

    @Test func persistedIndexLoadsOfflineAndIsIsolatedByServer() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = UUID()
        let online = SearchLibraryStub()
        online.indexedSongs = [DisplayableSong(id: "saved", title: "Saved instrumental").asSong()]
        let first = LibraryIndexService(serverID: { server }, directory: directory)
        await first.rebuildAndWait(using: online)

        let offline = SearchLibraryStub()
        let restored = LibraryIndexService(serverID: { server }, networkAvailable: { false }, directory: directory)
        await restored.rebuildAndWait(using: offline)
        #expect(restored.search(query: "instrumental").songs.map(\.id) == ["saved"])
        #expect(offline.searchCalls.isEmpty && offline.songOffsets.isEmpty)
        let other = UUID()
        let isolated = LibraryIndexService(serverID: { other }, networkAvailable: { false }, directory: directory)
        await isolated.rebuildAndWait(using: offline)
        #expect(isolated.search(query: "instrumental").songs.isEmpty)
    }
}
