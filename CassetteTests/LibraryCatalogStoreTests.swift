import Foundation
import Testing
import SwiftSonic
@testable import Cassette

@MainActor
struct LibraryCatalogStoreTests {
    private func snapshot(_ songs: [DisplayableSong], date: Date = Date()) -> LibraryIndexService.Snapshot {
        .init(artists: [], albums: [], playlists: [], songs: songs, date: date)
    }

    @Test func durableSearchReconcilesRenamesDeletesAndShortHangulQueries() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("catalog.sqlite")
        let first = snapshot([.init(id: "1", title: "사랑 노래"), .init(id: "2", title: "Instrumental")])
        try LibraryCatalogStore.save(first, to: file)
        #expect(try LibraryCatalogStore.search("사랑", limit: 10, at: file).songs.map(\.id) == ["1"])
        #expect(try LibraryCatalogStore.search("strument", limit: 10, at: file).songs.map(\.id) == ["2"])
        // OR is a literal token: it matches the romanized "norae", never an FTS operator.
        #expect(try LibraryCatalogStore.search("\" OR *", limit: 10, at: file).songs.map(\.id) == ["1"])
        // Same count, different tags and membership: old FTS entries must disappear.
        let next = snapshot([.init(id: "1", title: "새로운 제목"), .init(id: "3", title: "Piano")])
        try LibraryCatalogStore.save(next, to: file)
        #expect(try LibraryCatalogStore.search("사랑", limit: 10, at: file).songs.isEmpty)
        #expect(try LibraryCatalogStore.search("Instrumental", limit: 10, at: file).songs.isEmpty)
        #expect(try LibraryCatalogStore.search("제목", limit: 10, at: file).songs.map(\.id) == ["1"])
        #expect(try LibraryCatalogStore.load(from: file)?.songs.map(\.id) == ["1", "3"])
    }

    @Test func largeCatalogReopensWithIndexedSubstringSearch() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("large.sqlite")
        let songs = (0..<10000).map { DisplayableSong(id: "\($0)", title: "Catalog track \($0)") }
        try LibraryCatalogStore.save(snapshot(songs), to: file)
        #expect(try LibraryCatalogStore.load(from: file)?.songs.count == 10000)
        let start = ContinuousClock.now
        let hits = try LibraryCatalogStore.search("9999", limit: 81, at: file)
        print("SQLite FTS, 10,000 tracks: \(start.duration(to: .now))")
        #expect(hits.songs.map(\.id) == ["9999"])
        #expect(try LibraryCatalogStore.search("track", limit: 81, at: file).songs.count == 81)
    }

    @Test func legacyJSONMigratesOfflineWithoutServerRequests() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let server = UUID()
        try JSONEncoder().encode(snapshot([.init(id: "saved", title: "Saved")]))
            .write(to: dir.appendingPathComponent("\(server).json"))
        let index = LibraryIndexService(serverID: { server }, networkAvailable: { false }, directory: dir)
        let library = SearchLibraryStub()
        #expect(await index.ensureIndexedAndWait(using: library))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(server).sqlite").path))
        #expect(await index.searchInBackground(query: "saved").songs.map(\.id) == ["saved"])
        #expect(library.songOffsets.isEmpty)
    }

    @Test func bulkArtworkDoesNotInventPerTrackRequestsForAlbumFallbacks() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let server = UUID()
        let songs = [DisplayableSong(id: "album-fallback", title: "Fallback", albumId: "album"),
                     DisplayableSong(id: "alternate", title: "Alternate", albumId: "album", coverArtId: "alternate-cover"),
                     DisplayableSong(id: "single", title: "Single")]
        try JSONEncoder().encode(snapshot(songs)).write(to: dir.appendingPathComponent("\(server).json"))
        let index = LibraryIndexService(serverID: { server }, networkAvailable: { false }, directory: dir)
        #expect(await index.ensureIndexedAndWait(using: SearchLibraryStub()))
        #expect(index.songArtworkSnapshot["song:album-fallback"] == nil)
        #expect(index.songArtworkSnapshot["song:alternate"] == "alternate-cover")
        #expect(index.songArtworkSnapshot["song:single"] == "single")
    }

    @Test func sameCountMetadataChangesAreRevalidated() {
        let now = Date()
        #expect(!LibraryChangeDetector.needsMetadataRefresh(lastIndexedAt: now, lastScan: now, now: now))
        #expect(LibraryChangeDetector.needsMetadataRefresh(lastIndexedAt: now, lastScan: now.addingTimeInterval(1), now: now))
        #expect(LibraryChangeDetector.needsMetadataRefresh(lastIndexedAt: now.addingTimeInterval(-86400), lastScan: nil, now: now))
    }

    @Test("Exactly full local pages have no phantom More", arguments: [80, 160])
    func exactLocalPage(count: Int) async {
        let library = SearchLibraryStub()
        library.songPageCap = 500
        library.indexedSongs = (0..<count).map { DisplayableSong(id: "\($0)", title: "Match \($0)").asSong() }
        let index = LibraryIndexService()
        #expect(await index.rebuildAndWait(using: library))
        let vm = SearchViewModel(libraryService: library, libraryIndex: index)
        await vm.search(query: "Match")
        if count > 80 { #expect(vm.canLoadMore(.songs)); await vm.loadMore(category: .songs) }
        #expect(vm.songs.count == count)
        #expect(!vm.canLoadMore(.all))
    }

    @Test func finalRemotePageStopsPagingAfterExplicitLoadMore() async {
        let library = SearchLibraryStub()
        library.pageHandler = { _, page in
            .init(song: page.songOffset == 0 ? [DisplayableSong(id: "1", title: "Only").asSong()] : [])
        }
        let vm = SearchViewModel(libraryService: library)
        await vm.search(query: "Only")
        #expect(vm.songs.count == 1)
        // The first page no longer waits on a speculative request. A short page
        // may be a server cap; an explicit next page establishes end-of-results.
        #expect(vm.canLoadMore(.songs))
        await vm.loadMore(category: .songs)
        #expect(vm.songs.count == 1)
        #expect(!vm.canLoadMore(.all))
    }

    @Test func automaticCellularPrefersHLSButLosslessAndExplicitRoutesWin() {
        var input = PlaybackDecisionPolicy.Inputs(supportsDirectPlay: true, supportsTranscoding: true,
            supportsHLSTranscoding: true, container: "mp3", codec: "mp3", isCellular: true)
        #expect(PlaybackDecisionPolicy.decide(input).route == .hls)
        input.preferLossless = true
        input.container = "flac"; input.codec = "flac"
        #expect(PlaybackDecisionPolicy.decide(input).route == .directPlay)
        input.requestedRoute = .universal
        #expect(PlaybackDecisionPolicy.decide(input).route == .universal)
        let flac = DisplayableSong(id: "flac", title: "FLAC", audioFormat: "flac")
        #expect(PlaybackDecisionPolicy.preservesLosslessOriginal(song: flac))
    }
}
