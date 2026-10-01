// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import SwiftData

/// Lightweight, persistent song metadata for Siri/Spotlight lookups.
///
/// This is the *search* cache only — enough to build a `CassetteSongEntity`
/// without hitting the server. It deliberately does NOT store the full
/// playback metadata (ReplayGain, codecs, etc.), which always comes fresh from
/// `MediaResolver`/`LibraryService` when a song is actually played.
@Model
final class LibraryMetadataSong {
    /// Namespaced `"{serverId}:{songId}"`, unique across the whole store.
    @Attribute(.unique) var id: String
    var songId: String
    var serverId: UUID
    var title: String
    var artist: String?
    var albumId: String?
    var albumName: String?
    var artistId: String?
    var genre: String?
    var duration: TimeInterval
    var isrc: String?
    var displayComposer: String?
    var coverArtId: String?
    var indexedAt: Date

    init(
        song: DisplayableSong,
        serverId: UUID,
        indexedAt: Date = Date()
    ) {
        self.id = CassetteEntityID(serverId: serverId, localId: song.id).rawValue
        self.songId = song.id
        self.serverId = serverId
        self.title = song.title
        self.artist = song.artist
        self.albumId = song.albumId
        self.albumName = song.albumName
        self.artistId = song.artistId
        self.genre = song.genre
        self.duration = song.duration
        self.isrc = song.isrc
        self.displayComposer = song.displayComposer
        self.coverArtId = song.coverArtId
        self.indexedAt = indexedAt
    }

    /// Applies fresh values in place during an upsert.
    func apply(_ song: DisplayableSong, serverId: UUID) {
        self.songId = song.id
        self.serverId = serverId
        self.title = song.title
        self.artist = song.artist
        self.albumId = song.albumId
        self.albumName = song.albumName
        self.artistId = song.artistId
        self.genre = song.genre
        self.duration = song.duration
        self.isrc = song.isrc
        self.displayComposer = song.displayComposer
        self.coverArtId = song.coverArtId
        self.indexedAt = Date()
    }

    /// Reconstructs the subset `DisplayableSong` needed for entity mapping.
    func toDisplayableSong() -> DisplayableSong {
        DisplayableSong(
            id: songId,
            title: title,
            artist: artist,
            albumId: albumId,
            albumName: albumName,
            artistId: artistId,
            genre: genre,
            duration: duration,
            coverArtId: coverArtId,
            isrc: isrc,
            displayComposer: displayComposer
        )
    }
}
