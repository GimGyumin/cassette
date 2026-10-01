// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import Observation
import OSLog
import SwiftSonic

@Observable
@MainActor
final class HomeViewModel {
    private(set) var recentAlbums: [AlbumID3] = []
    private(set) var recentlyPlayed: [AlbumID3] = []
    private(set) var mostPlayed: [AlbumID3] = []
    private(set) var starredAlbums: [AlbumID3] = []
    private(set) var starredArtists: [ArtistID3] = []
    private(set) var starredSongs: [Song] = []
    var isLoading = false
    var error: UserFacingError?

    var hasStarredContent: Bool {
        !starredAlbums.isEmpty || !starredArtists.isEmpty || !starredSongs.isEmpty
    }

    private let libraryService: any LibraryServiceProtocol
    /// Skip catalog refetch when returning to the Library tab (`.task` restarts on tab reappear).
    private var didLoadCatalog = false
    private var didLoadStarred = false

    init(libraryService: any LibraryServiceProtocol) {
        self.libraryService = libraryService
    }

    /// Loads Favorites + catalog together and publishes results in one turn so
    /// `NavigationLink` trees don't re-register across multiple frames
    /// (`NavigationRequestObserver tried to update multiple times per frame`).
    func loadLibrary(force: Bool = false) async {
        if didLoadCatalog, didLoadStarred, !force { return }

        let needStarred = force || !didLoadStarred
        let needCatalog = force || !didLoadCatalog
        guard needStarred || needCatalog else { return }

        isLoading = true
        error = nil

        async let starredTask: (albums: [AlbumID3], artists: [ArtistID3], songs: [Song], loaded: Bool)? = {
            guard needStarred else { return nil }
            do {
                let starred = try await libraryService.getStarred2()
                return (
                    Array((starred.album ?? []).prefix(16)),
                    Array((starred.artist ?? []).prefix(16)),
                    Array((starred.song ?? []).prefix(16)),
                    true
                )
            } catch {
                if Self.isCancellation(error) { return nil }
                Logger.library.error("Failed to load starred shelf: \(error, privacy: .public)")
                // Mark loaded so we don't hammer a broken endpoint every tab switch.
                return ([], [], [], true)
            }
        }()

        async let catalogTask: (added: [AlbumID3], played: [AlbumID3], most: [AlbumID3], error: Error?)? = {
            guard needCatalog else { return nil }
            do {
                async let a = libraryService.recentlyAddedAlbums(size: 60)
                async let p = libraryService.recentlyPlayedAlbums(size: 20)
                async let m = libraryService.mostPlayedAlbums(size: 20)
                let (added, played, most) = try await (a, p, m)
                return (added, played, most, nil)
            } catch {
                if Self.isCancellation(error) { return nil }
                return ([], [], [], error)
            }
        }()

        let starred = await starredTask
        let catalog = await catalogTask

        // Apply both shelves together — one observation turn for the Library scroll content.
        if let starred {
            starredAlbums = starred.albums
            starredArtists = starred.artists
            starredSongs = starred.songs
            if starred.loaded { didLoadStarred = true }
        }

        if let catalog {
            if let err = catalog.error {
                self.error = UserFacingError.from(err)
            } else {
                recentAlbums = catalog.added
                recentlyPlayed = catalog.played
                mostPlayed = catalog.most
                didLoadCatalog = true
            }
        }

        isLoading = false
    }

    func load(force: Bool = false) async {
        await loadLibrary(force: force)
    }

    /// Refreshes the Library-top Favorites shelf from `getStarred2`.
    func loadStarred(force: Bool = false) async {
        if didLoadStarred, !force { return }
        do {
            let starred = try await libraryService.getStarred2()
            starredAlbums = Array((starred.album ?? []).prefix(16))
            starredArtists = Array((starred.artist ?? []).prefix(16))
            starredSongs = Array((starred.song ?? []).prefix(16))
            didLoadStarred = true
        } catch {
            // Don't mark loaded on cancel — tab switches cancel in-flight work (-999).
            if !Self.isCancellation(error) {
                Logger.library.error("Failed to load starred shelf: \(error, privacy: .public)")
                didLoadStarred = true
            }
        }
    }

    nonisolated private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorCancelled { return true }
        return (error as? URLError)?.code == .cancelled
    }
}
