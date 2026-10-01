// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import SwiftSonic

/// The Siri-facing catalog facade.
///
/// One seam for every App Intent need:
/// - entity lookups (Siri resolution, Spotlight, onscreen awareness), and
/// - playback resolution (`DisplayableSong`), which stays the only type
///   `PlayerService` consumes.
///
/// Implementations are local-first and must not fetch the whole library on a
/// Siri request. Implemented in Phase 2; resolved through `SiriBridge` so the
/// intents never hold a service reference directly.
@available(iOS 27.0, macOS 27.0, *)
protocol SiriCatalogServiceProtocol: AnyObject, Sendable {
    // MARK: - Entity lookups

    func songs(matching query: String, limit: Int) async -> [CassetteSongEntity]
    func song(id: CassetteEntityID) async -> CassetteSongEntity?

    func albums(matching query: String, limit: Int) async -> [CassetteAlbumEntity]
    func album(id: CassetteEntityID) async -> CassetteAlbumEntity?

    func artists(matching query: String, limit: Int) async -> [CassetteArtistEntity]
    func artist(id: CassetteEntityID) async -> CassetteArtistEntity?

    func playlists(matching query: String, limit: Int) async -> [CassettePlaylistEntity]
    func playlist(id: CassetteEntityID) async -> CassettePlaylistEntity?

    /// Favorites / recently played fallback for an open-ended “play some music”.
    func suggestedSongs(limit: Int) async -> [CassetteSongEntity]

    // MARK: - Playback resolution

    func playableSong(id: CassetteEntityID) async -> DisplayableSong?
    func playableSongs(inAlbum id: CassetteEntityID) async -> [DisplayableSong]
    func playableSongs(byArtist id: CassetteEntityID) async -> [DisplayableSong]
    func playableSongs(inPlaylist id: CassetteEntityID) async -> [DisplayableSong]

    /// Full server song record for mutations (e.g. adding to a playlist).
    func songRecord(id: CassetteEntityID) async -> Song?

    // MARK: - Library warmup

    /// Proactively warms the song-metadata store and reindexes Spotlight for every
    /// entity type. Called once per server (first install / fresh login) so Siri
    /// entity resolution — “like this song”, “play this artist”, “add to playlist” —
    /// works before any in-app search has populated the caches.
    func warmLibraryForSiri() async

    // MARK: - Bounded full-catalog listings (Spotlight reindex)

    func allSongs(limit: Int) async -> [CassetteSongEntity]
    func allAlbums(limit: Int) async -> [CassetteAlbumEntity]
    func allArtists(limit: Int) async -> [CassetteArtistEntity]
    func allPlaylists(limit: Int) async -> [CassettePlaylistEntity]
}
