// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import AppIntents
import Foundation

/// Builds `EntityIdentifier`s for onscreen awareness.
///
/// Attaching these to a visible row lets Siri understand “this song” or “the
/// third one” without OCR. Entities are iOS 27-gated, so older OSes get `nil`.
@available(iOS 27.0, macOS 27.0, *)
enum OnscreenEntityAnnotation {
    @MainActor
    static func songIdentifier(for song: DisplayableSong, serverId: UUID?) -> EntityIdentifier? {
        guard let serverId else { return nil }
        return EntityIdentifier(for: CassetteSongEntity(song: song, serverId: serverId, loadRelations: false))
    }

    static func albumIdentifier(
        id: String,
        title: String,
        artist: String?,
        serverId: UUID?
    ) -> EntityIdentifier? {
        guard let serverId else { return nil }
        let entity = CassetteAlbumEntity(
            id: CassetteEntityID(serverId: serverId, localId: id).rawValue,
            title: title,
            artistName: CassetteEntityDisplay.artistName(artist)
        )
        return EntityIdentifier(for: entity)
    }

    static func artistIdentifier(id: String, name: String, serverId: UUID?) -> EntityIdentifier? {
        guard let serverId else { return nil }
        return EntityIdentifier(for: CassetteArtistEntity(
            id: CassetteEntityID(serverId: serverId, localId: id).rawValue,
            name: name
        ))
    }

    static func playlistIdentifier(
        id: String,
        title: String,
        trackCount: Int,
        serverId: UUID?
    ) -> EntityIdentifier? {
        guard let serverId else { return nil }
        return EntityIdentifier(for: CassettePlaylistEntity(
            id: CassetteEntityID(serverId: serverId, localId: id).rawValue,
            title: title,
            trackCount: trackCount
        ))
    }
}
