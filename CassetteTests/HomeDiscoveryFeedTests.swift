import Foundation
import SwiftData
import SwiftSonic
import Synchronization
import Testing
@testable import Cassette

@Suite("Home and Discover metadata", .serialized) @MainActor
struct HomeDiscoveryFeedTests {
    private func state() -> ServerState {
        let state = ServerState()
        state.activeServer = ServerSnapshot(from: ServerConfig(displayName: "A", baseURL: "https://a.invalid", username: "a"))
        return state
    }

    @Test func bothTabsShareARefreshAndNeverShowThePreviousAccount() async throws {
        let state = state(), library = SearchLibraryStub()
        let held = HeldAuditResult<[Playlist]>()
        library.playlistsOperation = { await held.value() }
        let feed = HomeDiscoveryFeed(library: library, serverState: state)
        var starts = held.starts.makeAsyncIterator()
        let home = Task { await feed.load() }
        _ = await starts.next()
        let discover = Task { await feed.load() }
        await Task.yield()
        held.finish([Playlist(id: "a-playlist", name: "A", songCount: 0, duration: 0)])
        await home.value; await discover.value
        #expect(library.playlistListCalls == 1)
        #expect(feed.playlists.map(\.id) == ["a-playlist"])
        await feed.load()
        #expect(library.playlistListCalls == 1)
        state.activeServer = ServerSnapshot(from: ServerConfig(displayName: "B", baseURL: "https://b.invalid", username: "b"))
        #expect(feed.playlists.isEmpty && feed.favoriteSongs.isEmpty)
        library.playlistsOperation = { [Playlist(id: "b-playlist", name: "B", songCount: 0, duration: 0)] }
        await feed.load()
        #expect(feed.playlists.map(\.id) == ["b-playlist"])
        #expect(library.playlistListCalls == 2)
    }

    @Test func aLateHomeResponseCannotReplaceTheNewAccountsFeed() async {
        let state = state(), library = SearchLibraryStub(), held = HeldAuditResult<[Playlist]>()
        library.playlistsOperation = { await held.value() }
        let feed = HomeDiscoveryFeed(library: library, serverState: state)
        var starts = held.starts.makeAsyncIterator()
        let old = Task { await feed.load() }
        _ = await starts.next()
        state.activeServer = ServerSnapshot(from: ServerConfig(displayName: "B", baseURL: "https://b.invalid", username: "b"))
        library.playlistsOperation = { [Playlist(id: "b", name: "B", songCount: 0, duration: 0)] }
        await feed.load()
        held.finish([Playlist(id: "a", name: "A", songCount: 0, duration: 0)])
        await old.value
        #expect(feed.playlists.map(\.id) == ["b"] && !feed.isLoading)
    }

    @Test func genreShelvesDeduplicateAlbumsAndKeepDifferentAlbums() {
        let albums = [
            AlbumID3(id: "1", name: "Pop", songCount: 1, duration: 180, genre: "Pop"),
            AlbumID3(id: "1", name: "Duplicate", songCount: 1, duration: 180, genre: "Pop"),
            AlbumID3(id: "2", name: "Rock", songCount: 1, duration: 180, genre: "Rock"),
            AlbumID3(id: "3", name: "Other Pop", songCount: 1, duration: 180, genre: "pop")
        ]
        let shelves = HomeDiscoveryFeed.genreShelves(from: albums)
        #expect(shelves.map(\.title) == ["Pop", "Rock"])
        #expect(shelves.first?.albums.map(\.id) == ["1", "3"])
    }

    @Test func favoriteRowsKeepTheirOrderAndDownloadedMembership() async throws {
        let state = state(), library = SearchLibraryStub(), downloads = PDDownloadStub()
        downloads.downloadedIDs = ["b"]
        library.starredOperation = {
            try JSONDecoder().decode(Starred2.self, from: Data(#"{"song":[{"id":"a","title":"First"},{"id":"b","title":"Second"}]}"#.utf8))
        }
        let feed = HomeDiscoveryFeed(library: library, serverState: state, downloads: downloads)
        await feed.load()
        #expect(feed.favoriteSongs.map(\.id) == ["a", "b"])
        #expect(feed.favoriteSongs.map(\.isDownloaded) == [false, true])
    }

    @Test func automaticMixesRebuildAfterExpiryInsteadOfRenewingStaleTracks() async throws {
        let library = SearchLibraryStub()
        let clock = Mutex(Date(timeIntervalSince1970: 100))
        var edition = "a"
        library.recentAlbumsOperation = {
            [AlbumID3(id: "album", name: "Album", songCount: 5, duration: 900)]
        }
        library.albumOperation = { id in
            AlbumID3(id: id, name: "Album", songCount: 5, duration: 900,
                song: (0..<5).map { Song(id: "\(edition)-\($0)", title: "Track", duration: 180) })
        }
        let mixes = PersonalMixService(libraryService: library, statsService: StatsService(modelContainer: try .cassette(inMemory: true)),
                                       now: { clock.withLock { $0 } })
        let first = await mixes.mixes(serverId: "fixture")
        #expect(first.first?.tracks.first?.id == "a-0")
        edition = "b"
        #expect(await mixes.mixes(serverId: "fixture").first?.tracks.first?.id == "a-0")
        clock.withLock { $0 = $0.addingTimeInterval(91) }
        let updated = await mixes.mixes(serverId: "fixture")
        #expect(updated.first?.tracks.first?.id == "b-0")
        #expect(updated.first?.updatedAt == clock.withLock { $0 })
    }
}
