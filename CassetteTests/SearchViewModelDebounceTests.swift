// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Testing
import Foundation
import SwiftSonic
import SwiftData
import Observation
@testable import Cassette

private actor SearchIndexGate {
    private var open = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async {
        if open { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func release() { open = true; waiter?.resume(); waiter = nil }
}

@MainActor
struct SearchBrowseArtworkTests {
    @Test func backgroundGenreLookupPreservesFirstMatchAndArtworkFallback() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("browse-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = SearchLibraryStub()
        library.indexedSongs = try JSONDecoder().decode([Song].self, from: Data("""
            [{"id":"pop-first","title":"First","genre":"Póp","coverArt":"cover-pop"},
             {"id":"pop-second","title":"Second","genre":"Pop","coverArt":"later-cover"},
             {"id":"jazz-fallback","title":"Jazz","genre":"Jazz"},
             {"id":"hip-hop","title":"Rap","genre":"Hip-Hop/Rap","coverArt":"cover-rap"}]
            """.utf8))
        let index = LibraryIndexService(directory: directory)
        #expect(await index.rebuildAndWait(using: library))
        let covers = await index.browseCoverArtIDs(for: ["Pop", "Jazz", "Hip-Hop", "Classical"])
        #expect(covers == ["Pop": "cover-pop", "Jazz": "jazz-fallback", "Hip-Hop": "cover-rap"])
        index.clear()
        #expect(await index.browseCoverArtIDs(for: ["Pop"]).isEmpty)
    }
}

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

    var songOperation: ((String) async throws -> Song)?
    func song(id: String) async throws -> Song {
        guard let songOperation else { throw URLError(.unknown) }
        return try await songOperation(id)
    }
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
    var indexFailure: (any Error)?
    var indexGate: (() async -> Void)?
    var songPageCap = 20
    private(set) var songOffsets: [Int] = []
    var songsOperation: (() async throws -> [Song])?
    func librarySongs(offset: Int, count: Int) async throws -> [Song] {
        if let songsOperation { return try await songsOperation() }
        songOffsets.append(offset)
        return Array(indexedSongs.dropFirst(offset).prefix(min(count, songPageCap)))
    }
    var artistsOperation: (() async throws -> [ArtistIndex])?
    func artists() async throws -> [ArtistIndex] {
        if let artistsOperation { return try await artistsOperation() }
        await indexGate?()
        if let indexFailure { throw indexFailure }
        return []
    }
    func artist(id: String) async throws -> ArtistID3 { throw URLError(.unknown) }
    var albumOperation: ((String) async throws -> AlbumID3)?
    func album(id: String) async throws -> AlbumID3 {
        guard let albumOperation else { throw URLError(.unknown) }
        return try await albumOperation(id)
    }
    func fetchAllTracks(forArtistID artistID: String) async throws -> [DisplayableSong] { throw URLError(.unknown) }
    var playlistsOperation: (() async throws -> [Playlist])?
    private(set) var playlistListCalls = 0
    func playlists() async throws -> [Playlist] {
        playlistListCalls += 1
        if let playlistsOperation { return try await playlistsOperation() }
        return indexedPlaylists
    }
    func playlist(id: String) async throws -> PlaylistWithSongs { throw URLError(.unknown) }
    var coverURL: URL?
    var coverURLOperation: ((String, Int?) async -> URL?)?
    private(set) var coverSizes: [Int?] = []
    func coverArtURL(id: String, size: Int?) async -> URL? {
        coverSizes.append(size)
        if let coverURLOperation { return await coverURLOperation(id, size) }
        return coverURL
    }
    func streamURL(songId: String) async -> URL? { nil }
    var mutationOperation: ((Bool) async throws -> Void)?
    var starredOperation: (() async throws -> Starred2)?
    func star(songIds: [String], albumIds: [String], artistIds: [String]) async throws {
        guard let mutationOperation else { throw URLError(.unknown) }
        try await mutationOperation(true)
    }
    func unstar(songIds: [String], albumIds: [String], artistIds: [String]) async throws {
        guard let mutationOperation else { throw URLError(.unknown) }
        try await mutationOperation(false)
    }
    func getStarred2() async throws -> Starred2 {
        guard let starredOperation else { throw URLError(.unknown) }
        return try await starredOperation()
    }
    var recentAlbumsOperation: (() async throws -> [AlbumID3])?
    func recentlyAddedAlbums(size: Int) async throws -> [AlbumID3] {
        guard let recentAlbumsOperation else { throw URLError(.unknown) }
        return try await recentAlbumsOperation()
    }
    func allAlbums() async throws -> [AlbumID3] { [] }
    func scrobble(songId: String, submission: Bool) async {}
    func recentlyPlayedAlbums(size: Int) async throws -> [AlbumID3] { throw URLError(.unknown) }
    func mostPlayedAlbums(size: Int) async throws -> [AlbumID3] { throw URLError(.unknown) }
    func randomSongs(size: Int) async throws -> [Song] { throw URLError(.unknown) }
    var smartShuffleOperation: (() async throws -> [DisplayableSong])?
    var backfillOperation: (() async throws -> [DisplayableSong])?
    func smartShuffleQueue(targetSize: Int) async throws -> [DisplayableSong] {
        guard let smartShuffleOperation else { throw URLError(.unknown) }
        return try await smartShuffleOperation()
    }
    func similarBackfillQueue(targetSize: Int, excludedIds: Set<String>) async throws -> [DisplayableSong] {
        guard let backfillOperation else { throw URLError(.unknown) }
        return try await backfillOperation()
    }
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
    @Test("indexed results appear while download lookup is still pending")
    func localIndexDoesNotWaitForDownloads() async {
        let library = SearchLibraryStub()
        library.indexedSongs = [DisplayableSong(id: "local", title: "Instrumental").asSong()]
        let index = LibraryIndexService()
        #expect(await index.rebuildAndWait(using: library))
        var pending: CheckedContinuation<[DisplayableSong], Never>?
        let vm = SearchViewModel(libraryService: library, libraryIndex: index, downloads: { _ in
            await withCheckedContinuation { pending = $0 }
        })
        let request = Task { await vm.search(query: "instrumental") }
        while pending == nil { await Task.yield() }
        // Bounded wait makes the old serial download→index pipeline fail without hanging.
        let deadline = ContinuousClock.now + .seconds(2)
        while vm.rankedItems.isEmpty, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(vm.rankedItems.map(\.id) == ["song:local"])
        pending?.resume(returning: [DisplayableSong(id: "local", title: "Instrumental", isDownloaded: true)])
        await request.value
        #expect(vm.songs.first?.isDownloaded == true)
        #expect(library.searchCalls.isEmpty)
    }

    @Test func rankingPreservesRelevanceAndStableTies() {
        let items: [SearchResultItem] = [
            .song(DisplayableSong(id: "contains", title: "My café")),
            .song(DisplayableSong(id: "prefix-1", title: "Cafe One")),
            .song(DisplayableSong(id: "exact", title: "CAFÉ")),
            .song(DisplayableSong(id: "prefix-2", title: "Cafe Two"))
        ]
        #expect(SearchResultItem.ranked(items, query: "cafe", locale: Locale(identifier: "en_US"))
            .map(\.id) == ["song:exact", "song:prefix-1", "song:prefix-2", "song:contains"])
    }

    @Test func rankingFiltersUnrelatedServerResultsAndMatchesSongArtist() {
        let items: [SearchResultItem] = [
            .song(DisplayableSong(id: "artist-match", title: "No Surprises", artist: "Radiohead")),
            .song(DisplayableSong(id: "unrelated", title: "Midnight City", artist: "M83")),
            .song(DisplayableSong(id: "title-match", title: "Radiohead Live", artist: "Various Artists"))
        ]

        #expect(SearchResultItem.ranked(items, query: "radiohead", locale: Locale(identifier: "en_US"))
            .map(\.id) == ["song:title-match", "song:artist-match"])
    }

    @Test func multiwordQueriesRequireEveryToken() {
        let items: [SearchResultItem] = [
            .song(DisplayableSong(id: "match", title: "No Surprises", artist: "Radiohead")),
            .song(DisplayableSong(id: "partial", title: "No Surprises", artist: "Cover Band"))
        ]

        #expect(SearchResultItem.ranked(items, query: "radiohead surprises", locale: Locale(identifier: "en_US"))
            .map(\.id) == ["song:match"])
    }

    @Test func downloadSearchReturnsSnapshotsFromItsOwnContext() async throws {
        let container = try ModelContainer(for: DownloadedTrack.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let server = UUID()
        let context = ModelContext(container)
        context.insert(DownloadedTrack(songId: "match", serverId: server, filePath: "match.flac",
            fileSize: 100, mimeType: "audio/flac", title: "Café", durationSeconds: 123, bitRate: 900))
        context.insert(DownloadedTrack(songId: "other-server", serverId: UUID(), filePath: "other.flac",
            fileSize: 100, mimeType: "audio/flac", title: "Café"))
        try context.save()
        let store = SearchDownloadStore(modelContainer: container)
        let results = await store.matching("cafe", serverId: server)
        #expect(results.map(\.id) == ["match"])
        #expect(results.first?.duration == 123)
        #expect(results.first?.bitRate == 900)
        #expect(results.first?.isDownloaded == true)
    }
    @Test func lateDownloadSearchCannotReplaceANewerQuery() async {
        var pending: CheckedContinuation<[DisplayableSong], Never>?
        let vm = SearchViewModel(libraryService: SearchLibraryStub(), downloads: { _ in
            await withCheckedContinuation { pending = $0 }
        })
        let old = Task { await vm.search(query: "old", downloadsOnly: true) }
        while pending == nil { await Task.yield() }
        await vm.search(query: "")
        pending?.resume(returning: [DisplayableSong(id: "old", title: "Old song")])
        await old.value
        #expect(vm.songs.isEmpty)
        #expect(!vm.isSearching)
    }

    @Test func backgroundIndexSearchKeepsAllResultsAndHonorsCancellation() async {
        let stub = SearchLibraryStub()
        stub.songPageCap = 500
        stub.indexedSongs = (0..<250).map { DisplayableSong(id: "song-\($0)", title: "Instrumental \($0)").asSong() }
        let index = LibraryIndexService()
        await index.rebuildAndWait(using: stub)
        let results = await index.searchInBackground(query: "instrumental", limit: .max)
        #expect(results.songs.count == 250)
        #expect(results.songs.map(\.id) == index.search(query: "instrumental", limit: .max).songs.map(\.id))
        let cancelled = Task { await index.searchInBackground(query: "instrumental") }
        cancelled.cancel()
        #expect(await cancelled.value.songs.isEmpty)
    }

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
    @Test("first server page is ranked without an extra page request")
    func firstPageDoesNotWaitForPrefetch() async {
        let stub = SearchLibraryStub()
        var requests: [SearchPageRequest] = []
        stub.pageHandler = { _, page in
            requests.append(page)
            return self.songs(page.songOffset..<min(page.songOffset + 20, 40))
        }
        let vm = SearchViewModel(libraryService: stub)
        await vm.search(query: "inst")
        #expect(vm.rankedItems.count == 20)
        #expect(requests.map(\.songOffset) == [0])
        #expect(vm.canLoadMore(.songs))
        await vm.loadMore(category: .songs)
        #expect(requests.map(\.songOffset) == [0, 20])
        #expect(vm.rankedItems.count == 40)
    }

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
    @Test func firstSearchReturnsServerResultsBeforeIndexCompletes() async throws {
        let library = SearchLibraryStub()
        let gate = SearchIndexGate()
        library.indexGate = { await gate.wait() }
        library.pageHandler = { _, _ in
            SearchResult3(song: [DisplayableSong(id: "remote", title: "First song").asSong()])
        }
        let index = LibraryIndexService()
        let vm = SearchViewModel(libraryService: library, libraryIndex: index)
        await vm.search(query: "First")
        #expect(index.isPreparing)
        #expect(vm.songs.map(\.id) == ["remote"])
        #expect(!vm.isSearching)
        await gate.release()
        await index.ensureIndexedAndWait(using: library)
    }

    @Test func offlineFirstSearchDoesNotSendAServerRequest() async {
        let library = SearchLibraryStub()
        let index = LibraryIndexService(networkAvailable: { false })
        let vm = SearchViewModel(libraryService: library, libraryIndex: index)
        await vm.search(query: "First", serverReachable: false)
        #expect(library.searchCalls.isEmpty)
    }
    @Test func unchangedLaunchRestoresSilentlyAndExplicitRebuildStillRefreshes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = UUID()
        let library = SearchLibraryStub()
        library.indexedSongs = [DisplayableSong(id: "saved", title: "Saved track").asSong()]
        let first = LibraryIndexService(serverID: { server }, directory: directory)
        await first.rebuildAndWait(using: library)

        let nextLaunchLibrary = SearchLibraryStub()
        nextLaunchLibrary.indexedSongs = [DisplayableSong(id: "new", title: "New track").asSong()]
        let restored = LibraryIndexService(serverID: { server }, directory: directory)
        // A relaunch must not briefly publish true even while restoring a large snapshot.
        withObservationTracking { _ = restored.isIndexing } onChange: {
            Issue.record("Restoring an existing index must not publish an indexing state")
        }
        restored.ensureIndexed(using: nextLaunchLibrary)
        await restored.ensureIndexedAndWait(using: nextLaunchLibrary)
        #expect(nextLaunchLibrary.songOffsets.isEmpty)
        #expect(restored.search(query: "saved").songs.map(\.id) == ["saved"])
        #expect(restored.lastIndexedAt == first.lastIndexedAt)
        #expect(!restored.isIndexing)

        // Use another instance so the no-change observation above only covers the launch path.
        let changed = LibraryIndexService(serverID: { server }, directory: directory)
        await changed.rebuildAndWait(using: nextLaunchLibrary)
        #expect(!nextLaunchLibrary.songOffsets.isEmpty)
        #expect(changed.search(query: "new").songs.map(\.id) == ["new"])
    }

    @Test func missingOrCorruptIndexStillBuildsAndConcurrentEnsuresShareWork() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for corrupt in [false, true] {
            let server = UUID()
            if corrupt { try Data("invalid snapshot".utf8).write(to: directory.appendingPathComponent("\(server).json")) }
            let library = SearchLibraryStub()
            library.indexedSongs = [DisplayableSong(id: "new", title: "New track").asSong()]
            let index = LibraryIndexService(serverID: { server }, directory: directory)
            index.ensureIndexed(using: library)
            index.ensureIndexed(using: library)
            await index.ensureIndexedAndWait(using: library)
            #expect(library.songOffsets == [0, 1])
            #expect(index.search(query: "new").songs.map(\.id) == ["new"])
            #expect(!index.isIndexing)
        }
    }

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

    @Test func failedIndexFallsBackToServerAndCanBeRetried() async {
        let library = SearchLibraryStub()
        library.indexFailure = URLError(.cannotConnectToHost)
        let index = LibraryIndexService()
        let built = await index.rebuildAndWait(using: library)
        #expect(!built)
        #expect(index.lastError != nil)

        let vm = SearchViewModel(libraryService: library, libraryIndex: index)
        await vm.search(query: "available")
        #expect(library.searchCalls == ["available"])
        #expect(vm.searchError == nil)

        await vm.search(query: "offline", serverReachable: false)
        #expect(vm.searchError?.id == UserFacingError.searchIndexUnavailable.id)

        library.indexFailure = nil
        library.indexedSongs = [DisplayableSong(id: "recovered", title: "Recovered").asSong()]
        await vm.retryLocalIndexIfNeeded()
        await vm.search(query: "recovered")
        #expect(vm.songs.map(\.id) == ["recovered"])
        #expect(library.searchCalls == ["available"])
    }

    @Test func largeIndexPagesResultsWithoutServerRequests() async {
        let library = SearchLibraryStub()
        library.songPageCap = 500
        library.indexedSongs = (0..<180).map { DisplayableSong(id: "song-\($0)", title: "Instrumental \($0)").asSong() }
        let index = LibraryIndexService()
        await index.rebuildAndWait(using: library)
        let vm = SearchViewModel(libraryService: library, libraryIndex: index)
        await vm.search(query: "instrumental")
        #expect(vm.songs.count == 80)
        #expect(vm.canLoadMore(.songs))
        await vm.loadMore(category: .songs)
        #expect(vm.songs.count == 160)
        await vm.loadMore(category: .songs)
        #expect(vm.songs.count == 180)
        #expect(!vm.canLoadMore(.songs))
        #expect(library.searchCalls.isEmpty)
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
