// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import SwiftSonic

/// All value-based navigation destinations reachable from the Home tab NavigationStack.
/// Registered via .navigationDestination(for: HomeDestination.self) on HomeView.
nonisolated enum HomeDestination: Hashable {

    // MARK: - Library sections (iOS only — macOS uses NavigationSplitView sidebar)
    case libraryAlbums
    case libraryArtists
    case librarySongs
    case libraryPlaylists
    case libraryFavorites
    case libraryDownloads

    // MARK: - Content destinations (iOS + macOS)
    /// Full AlbumID3 object — used from Recently Added, Recently Played carousels
    case album(AlbumID3)
    /// Full ArtistID3 object
    case artist(ArtistID3)
    /// Full Playlist object
    case playlist(Playlist)
    /// Full DownloadedAlbumDisplay object — used from downloaded content carousels
    case downloadedAlbum(DownloadedAlbumDisplay)

    // MARK: - ID-only destinations (for PinnedItem @Model and DownloadedItem)
    /// Used when only IDs are available (PinnedItem @Model, HomeDownloadedItemCard)
    case albumById(id: String, name: String, subtitle: String, coverArtId: String?)
    case playlistById(id: String, name: String, coverArtId: String?)
    case artistById(id: String, name: String, coverArtId: String?)

    // MARK: - Unique in-page pushes
    /// An artist pushed from inside another page (album header, playlist header, Now Playing).
    ///
    /// `artistById` is Hashable by content, and `NavigationStack` maps an equal path value onto the entry
    /// that already holds it: pushing the same artist again at a deeper level pops the stack instead of
    /// stacking, which leaves the back button pointing at a removed entry (blank page / a back button that
    /// no longer responds). `token` is a per-push identity — `@State` on the pushing page, or one `UUID()`
    /// per notification payload — so the value stays stable for the life of the entry and unique along the
    /// path, which makes every push a new stack entry.
    case artistPush(id: String, name: String, coverArtId: String?, token: UUID)

    // MARK: - Replay (Wrapped)
    /// Listening Replay root — must live on NavigationPath so artist/album pushes stack correctly.
    case replay
    /// Replay opened to a specific month/year period.
    case replayPeriod(WrappedPeriod)

    // MARK: - Offline-derived destinations
    /// Offline artist summary — used from OfflineBrowseContent
    case offlineArtist(OfflineArtistSummary)
    /// Offline album summary — used from OfflineArtistAlbumsView
    case offlineAlbum(OfflineAlbumSummary)

    // MARK: - Personal mixes (Home “Made for You”)
    /// Client-built updating mix — not a server playlist id.
    case personalMix(PersonalMixKind)
}
