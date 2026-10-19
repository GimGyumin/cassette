import Foundation
import Observation
import SwiftSonic

/// Shared metadata for Home and Discover. One account-scoped refresh serves both tabs.
@MainActor @Observable
final class HomeDiscoveryFeed {
    private var playlistItems: [Playlist] = []
    private var favoriteSongItems: [DisplayableSong] = []
    private var favoriteArtistItems: [ArtistID3] = []
    private var recentlyAddedItems: [AlbumID3] = []
    private(set) var isLoading = false
    private let library: any LibraryServiceProtocol
    private let serverState: ServerState
    private let downloads: (any DownloadServiceProtocol)?
    private var identity: ServerRequestIdentity?
    private var refreshedAt: Date?
    private var generation = 0
    private var task: Task<Void, Never>?

    private var matchesActiveAccount: Bool { identity.map(serverState.requestIsCurrent) == true }
    var playlists: [Playlist] { matchesActiveAccount ? playlistItems : [] }
    var favoriteSongs: [DisplayableSong] { matchesActiveAccount ? favoriteSongItems : [] }
    var favoriteArtists: [ArtistID3] { matchesActiveAccount ? favoriteArtistItems : [] }
    var recentlyAdded: [AlbumID3] { matchesActiveAccount ? recentlyAddedItems : [] }

    init(library: any LibraryServiceProtocol, serverState: ServerState, downloads: (any DownloadServiceProtocol)? = nil) {
        self.library = library
        self.serverState = serverState
        self.downloads = downloads
    }

    func load(forceRefresh: Bool = false) async {
        guard let sid = serverState.activeServer?.id, let request = try? serverState.requestIdentity(for: sid) else { return }
        if identity == request {
            if let task { await task.value; return }
            if !forceRefresh, let refreshedAt, Date().timeIntervalSince(refreshedAt) < 90 { return }
        } else {
            task?.cancel()
            playlistItems = []; favoriteSongItems = []; favoriteArtistItems = []; recentlyAddedItems = []
            refreshedAt = nil
        }
        identity = request
        generation += 1
        let token = generation
        isLoading = true
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.generation == token { self.isLoading = false; self.task = nil } }
            let lists = try? await self.library.playlists()
            guard self.isCurrent(request, token) else { return }
            if let lists { self.playlistItems = lists.sorted { ($0.changed ?? .distantPast) > ($1.changed ?? .distantPast) } }
            let starred = try? await self.library.getStarred2()
            guard self.isCurrent(request, token) else { return }
            if let starred {
                let downloaded = await self.downloads?.downloadedSongIds(serverId: sid) ?? []
                let prepared = try? await DisplayableSong.prepare(starred.song ?? [], downloadedIDs: downloaded)
                guard self.isCurrent(request, token), let prepared else { return }
                self.favoriteSongItems = prepared
                self.favoriteArtistItems = starred.artist ?? []
            }
            let added = try? await self.library.recentlyAddedAlbums(size: 50)
            guard self.isCurrent(request, token) else { return }
            if let added { self.recentlyAddedItems = added }
            if lists != nil || starred != nil || added != nil { self.refreshedAt = Date() }
        }
        self.task = task
        await task.value
    }

    private func isCurrent(_ request: ServerRequestIdentity, _ token: Int) -> Bool {
        !Task.isCancelled && generation == token && serverState.requestIsCurrent(request)
    }

    func stationArtists(from albums: [AlbumID3]) -> [ArtistID3] {
        var seen = Set<String>()
        let candidates = favoriteArtists + albums.compactMap { album -> ArtistID3? in
            guard let id = album.artistId, let name = album.artist else { return nil }
            return ArtistID3(id: id, name: name, coverArt: album.coverArt)
        }
        return Array(candidates.filter { seen.insert($0.id).inserted }.prefix(8))
    }

    func recentAlbumsFromYourArtists(_ frequentlyPlayed: [AlbumID3]) -> [AlbumID3] {
        let ids = Set(favoriteArtists.map(\.id) + frequentlyPlayed.compactMap(\.artistId))
        return recentlyAdded.filter { $0.artistId.map(ids.contains) == true }
    }

    static func genreShelves(from albums: [AlbumID3]) -> [(title: String, albums: [AlbumID3])] {
        var seen = Set<String>()
        var order: [String] = []
        var groups: [String: [AlbumID3]] = [:]
        var names: [String: String] = [:]
        for album in albums where seen.insert(album.id).inserted {
            guard let raw = album.genre?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { continue }
            let key = raw.lowercased()
            if groups[key] == nil { order.append(key); names[key] = raw }
            groups[key, default: []].append(album)
        }
        let preferred = ["pop", "k-pop", "rock", "r&b", "folk"]
        order.sort {
            let a = preferred.firstIndex(of: $0) ?? preferred.count
            let b = preferred.firstIndex(of: $1) ?? preferred.count
            return a == b ? $0 < $1 : a < b
        }
        return order.prefix(8).map { (names[$0] ?? $0, groups[$0] ?? []) }
    }
}
