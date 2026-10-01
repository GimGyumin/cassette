// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Testing
import Foundation
import SwiftData
import SwiftSonic
@testable import Cassette

// MARK: - Stub

/// Configurable library source: paginated song pages plus a starred-songs payload for the
/// Favorites filter. Records which offsets were requested so caching can be asserted.
@MainActor
private final class SongsLibraryStub: LibraryServiceProtocol {
    func song(id: String) async throws -> Song { throw URLError(.unknown) }
    var songPages: [Int: [Song]] = [:]
    var starredSongs: [Song] = []
    var starredShouldThrow = false
    private(set) var requestedOffsets: [Int] = []

    func librarySongs(offset: Int, count: Int) async throws -> [Song] {
        requestedOffsets.append(offset)
        return songPages[offset] ?? []
    }

    func getStarred2() async throws -> Starred2 {
        if starredShouldThrow { throw URLError(.notConnectedToInternet) }
        let payload = StarredPayload(song: starredSongs)
        let data = try JSONEncoder().encode(payload)
        return try JSONDecoder().decode(Starred2.self, from: data)
    }

    func artists() async throws -> [ArtistIndex] { throw URLError(.unknown) }
    func artist(id: String) async throws -> ArtistID3 { throw URLError(.unknown) }
    func album(id: String) async throws -> AlbumID3 { throw URLError(.unknown) }
    func fetchAllTracks(forArtistID artistID: String) async throws -> [DisplayableSong] { throw URLError(.unknown) }
    func playlists() async throws -> [Playlist] { throw URLError(.unknown) }
    func playlist(id: String) async throws -> PlaylistWithSongs { throw URLError(.unknown) }
    func search(_ query: String) async throws -> SearchResult3 { throw URLError(.unknown) }
    func coverArtURL(id: String, size: Int?) async -> URL? { nil }
    func streamURL(songId: String) async -> URL? { nil }
    func star(songIds: [String], albumIds: [String], artistIds: [String]) async throws { throw URLError(.unknown) }
    func unstar(songIds: [String], albumIds: [String], artistIds: [String]) async throws { throw URLError(.unknown) }
    func recentlyAddedAlbums(size: Int) async throws -> [AlbumID3] { throw URLError(.unknown) }
    func allAlbums() async throws -> [AlbumID3] { throw URLError(.unknown) }
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

/// `Starred2` has no public memberwise init, so fixtures round-trip through Codable.
private struct StarredPayload: Codable {
    let song: [Song]?
}


@Suite("Songs list")
@MainActor
struct SongsListViewModelTests {

    // MARK: - Helpers

    private func song(id: String, title: String, artist: String? = nil, created: Date? = nil) -> Song {
        Song(id: id, title: title, artist: artist, created: created)
    }

    private func makeVM(
        songs: [Song],
        container: ModelContainer? = nil,
        state: ServerState? = nil
    ) -> (SongsListViewModel, SongsLibraryStub) {
        let stub = SongsLibraryStub()
        stub.songPages = [0: songs]
        let vm = SongsListViewModel(libraryService: stub, modelContainer: container, serverState: state)
        return (vm, stub)
    }

    private func makeServerState() -> ServerState {
        let state = ServerState()
        state.activeServer = ServerSnapshot(from: ServerConfig(
            displayName: "S", baseURL: "https://s.example.com", username: "u", isActive: true
        ))
        return state
    }

    private func insertDownload(
        into container: ModelContainer,
        songId: String,
        title: String,
        artist: String?,
        serverId: UUID,
        downloadedAt: Date = Date()
    ) {
        let context = ModelContext(container)
        context.insert(
            DownloadedTrack(
                songId: songId,
                serverId: serverId,
                filePath: "\(songId).mp3",
                fileSize: 1_024,
                mimeType: "audio/mpeg",
                downloadedAt: downloadedAt,
                title: title,
                artist: artist
            )
        )
        try? context.save()
    }

    // MARK: - Grouping

    @Test("Title sort groups A–Z with # last")
    func titleSortGroupsAlphabetically() async {
        let (vm, _) = makeVM(songs: [
            song(id: "b", title: "Beta"),
            song(id: "n", title: "123 Song"),
            song(id: "a", title: "Alpha"),
        ])
        await vm.load()

        #expect(vm.sections.map(\.letter) == ["A", "B", "#"])
        #expect(vm.allSongs.map(\.title) == ["Alpha", "Beta", "123 Song"])
        #expect(vm.sections.map(\.startIndex) == [0, 1, 2])
        #expect(vm.usesAlphabetSections)
    }

    @Test("Artist sort groups by artist and orders titles within an artist")
    func artistSortGroupsByArtist() async {
        let (vm, _) = makeVM(songs: [
            song(id: "u", title: "Uwoo", artist: "BE'O"),
            song(id: "s", title: "Selfish", artist: "BE'O"),
            song(id: "l", title: "Love Lee", artist: "AKMU"),
            song(id: "x", title: "Untagged"),
        ])
        await vm.load()
        vm.setSort(.artist)

        #expect(vm.sections.map(\.letter) == ["A", "B", "#"])
        #expect(vm.sections[0].songs.map(\.id) == ["l"])
        // Within one artist the titles are ordered, and the artist-less song lands in "#".
        #expect(vm.sections[1].songs.map(\.id) == ["s", "u"])
        #expect(vm.sections[2].songs.map(\.id) == ["x"])
    }

    @Test("Date Added sort stays a flat newest-first list")
    func dateAddedSortIsFlat() async {
        let older = Date(timeIntervalSince1970: 1_000_000)
        let newer = Date(timeIntervalSince1970: 2_000_000)
        let (vm, _) = makeVM(songs: [
            song(id: "old", title: "Older", created: older),
            song(id: "none", title: "Undated"),
            song(id: "new", title: "Newer", created: newer),
        ])
        await vm.load()
        vm.setSort(.dateAdded)

        #expect(!vm.usesAlphabetSections)
        #expect(vm.sections.isEmpty)
        // Undated songs (server omitted `created`) sort last.
        #expect(vm.allSongs.map(\.id) == ["new", "old", "none"])
    }

    // MARK: - Filters

    @Test("Favorites filter swaps in the starred songs")
    func favoritesFilterUsesStarredSongs() async {
        let (vm, stub) = makeVM(songs: [song(id: "lib", title: "Library Song")])
        stub.starredSongs = [
            song(id: "f1", title: "Fearless", artist: "Taylor Swift"),
            song(id: "f2", title: "Anti-Hero", artist: "Taylor Swift"),
        ]
        await vm.load()
        await vm.setFilter(.favorites)

        #expect(vm.filter == .favorites)
        #expect(vm.allSongs.map(\.id) == ["f2", "f1"])
        #expect(vm.sections.map(\.letter) == ["A", "F"])
        #expect(!vm.hasMore, "Favorites are fetched whole — no pagination")
    }

    @Test("Downloads filter lists only the active server's local tracks")
    func downloadsFilterUsesLocalTracks() async throws {
        let container = try ModelContainer.cassette(inMemory: true)
        let state = makeServerState()
        let activeServerId = try #require(state.activeServer?.id)

        insertDownload(into: container, songId: "d1", title: "Downloaded", artist: "AKMU", serverId: activeServerId)
        insertDownload(into: container, songId: "other", title: "Other Server", artist: "AKMU", serverId: UUID())

        let (vm, _) = makeVM(songs: [song(id: "lib", title: "Library Song")], container: container, state: state)
        await vm.load()
        await vm.setFilter(.downloads)

        #expect(vm.filter == .downloads)
        #expect(vm.allSongs.map(\.id) == ["d1"])
        #expect(vm.allSongs.first?.isDownloaded == true)
        #expect(!vm.hasMore)
    }

    @Test("Library songs already downloaded locally are flagged for the badge")
    func librarySongsCarryDownloadedFlag() async throws {
        let container = try ModelContainer.cassette(inMemory: true)
        let state = makeServerState()
        let activeServerId = try #require(state.activeServer?.id)

        insertDownload(into: container, songId: "s1", title: "Alpha", artist: nil, serverId: activeServerId)

        let (vm, _) = makeVM(
            songs: [song(id: "s1", title: "Alpha"), song(id: "s2", title: "Beta")],
            container: container,
            state: state
        )
        await vm.load()

        #expect(vm.allSongs.first { $0.id == "s1" }?.isDownloaded == true)
        #expect(vm.allSongs.first { $0.id == "s2" }?.isDownloaded == false)
    }

    @Test("Switching back to All Songs reuses the cached pages")
    func returningToAllSongsDoesNotRefetch() async {
        let (vm, stub) = makeVM(songs: [song(id: "lib", title: "Library Song")])
        stub.starredSongs = [song(id: "f1", title: "Starred")]
        await vm.load()
        await vm.setFilter(.favorites)
        await vm.setFilter(.allSongs)

        #expect(vm.filter == .allSongs)
        #expect(vm.allSongs.map(\.id) == ["lib"])
        #expect(stub.requestedOffsets == [0], "The library page should be served from cache")
    }

    @Test("Favorites failure surfaces an error and empties the list")
    func favoritesFailureSetsError() async {
        let (vm, stub) = makeVM(songs: [song(id: "lib", title: "Library Song")])
        stub.starredShouldThrow = true
        await vm.load()
        await vm.setFilter(.favorites)

        #expect(vm.allSongs.isEmpty)
        #expect(vm.error != nil)
    }

    // MARK: - Pagination

    @Test("Pagination appends the next page and stops on a short page")
    func paginationAppendsPages() async {
        let firstPage = (0..<500).map { song(id: "p0-\($0)", title: "Track \($0)") }
        let (vm, stub) = makeVM(songs: firstPage)
        stub.songPages[500] = [
            song(id: "p1-0", title: "Zebra"),
            song(id: "p1-1", title: "Apple"),
        ]
        await vm.load()

        #expect(vm.allSongs.count == 500)
        #expect(vm.hasMore)

        await vm.loadMoreIfNeeded()
        #expect(vm.allSongs.count == 502)
        #expect(!vm.hasMore)
        // The appended page joins the alphabetical order instead of being tacked onto the end.
        #expect(vm.allSongs.first?.id == "p1-1")
        #expect(stub.requestedOffsets == [0, 500])

        // Once exhausted, further scroll callbacks must not hit the server again.
        await vm.loadMoreIfNeeded()
        #expect(stub.requestedOffsets == [0, 500])
    }

    @Test("Pagination is a no-op for the Favorites filter")
    func paginationSkippedForFavorites() async {
        let (vm, stub) = makeVM(songs: [song(id: "lib", title: "Library Song")])
        stub.starredSongs = [song(id: "f1", title: "Starred")]
        await vm.load()
        await vm.setFilter(.favorites)
        await vm.loadMoreIfNeeded()

        #expect(stub.requestedOffsets == [0])
    }
}
