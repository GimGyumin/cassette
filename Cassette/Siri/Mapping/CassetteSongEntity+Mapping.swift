// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import SwiftSonic

/// Maps Cassette's playback model (`DisplayableSong`) onto the `.audio.song` schema.
///
/// Kept out of the entity type so the entity stays a pure value and the mapping
/// rules stay testable in isolation.
@available(iOS 27.0, macOS 27.0, *)
extension CassetteSongEntity {
    /// - Parameter loadRelations: `false` builds a flat entity without artist /
    ///   album relations. List queries use it to avoid materializing the whole
    ///   relation graph for results Siri may never display.
    init(song: DisplayableSong, serverId: UUID, loadRelations: Bool = true) {
        id = CassetteEntityID(serverId: serverId, localId: song.id).rawValue
        duration = song.duration
        title = song.title
        artistName = CassetteEntityDisplay.artistName(song.artist)
        albumTitle = song.albumName
        internationalStandardRecordingCode = song.isrc

        if loadRelations {
            let songArtist = song.artist
            if let songArtist, !songArtist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                artists = [Self.artistEntity(artist: songArtist, artistId: song.artistId, serverId: serverId)]
            } else {
                artists = []
            }
            album = Self.albumEntity(for: song, serverId: serverId)
            composers = Self.composerEntities(composerName: song.displayComposer, serverId: serverId)
            composerName = song.displayComposer
        } else {
            artists = []
            album = nil
            composers = []
            composerName = nil
        }
    }

    private static func artistEntity(artist: String, artistId: String?, serverId: UUID) -> CassetteArtistEntity {
        if let artistId, !artistId.isEmpty {
            return CassetteArtistEntity(
                id: CassetteEntityID(serverId: serverId, localId: artistId).rawValue,
                name: artist
            )
        }
        return CassetteArtistEntity(serverId: serverId, name: artist)
    }

    private static func albumEntity(for song: DisplayableSong, serverId: UUID) -> CassetteAlbumEntity? {
        guard let albumId = song.albumId, !albumId.isEmpty else { return nil }
        return CassetteAlbumEntity(
            id: CassetteEntityID(serverId: serverId, localId: albumId).rawValue,
            title: song.albumName ?? "",
            artistName: CassetteEntityDisplay.artistName(song.artist),
            artists: song.artist.map { [Self.artistEntity(artist: $0, artistId: song.artistId, serverId: serverId)] } ?? []
        )
    }

    private static func composerEntities(composerName: String?, serverId: UUID) -> [CassetteArtistEntity] {
        guard let composerName, !composerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }
        // Navidrome exposes composers as display strings only — no composer ids.
        return [CassetteArtistEntity(serverId: serverId, name: composerName)]
    }
}
