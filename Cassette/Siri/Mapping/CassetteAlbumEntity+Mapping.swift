// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import SwiftSonic

/// Constructors for `CassetteAlbumEntity`.
@available(iOS 27.0, macOS 27.0, *)
extension CassetteAlbumEntity {
    /// General-purpose internal constructor. Parameter names never shadow the
    /// schema properties so the implicit-self assignments below initialize the
    /// macro-wrapped backing storage directly.
    init(
        id entityID: String,
        title albumTitle: String,
        artistName albumArtistName: String,
        artists albumArtists: [CassetteArtistEntity] = [],
        universalProductCode upc: String? = nil
    ) {
        id = entityID
        title = albumTitle
        artistName = albumArtistName
        artists = albumArtists
        universalProductCode = upc
    }

    /// - Parameter loadRelations: `false` skips building `artists`, which keeps
    ///   album list queries cheap.
    init(album: AlbumID3, serverId: UUID, loadRelations: Bool = true) {
        let artistName = CassetteEntityDisplay.artistName(album.artist)
        self.init(
            id: CassetteEntityID(serverId: serverId, localId: album.id).rawValue,
            title: album.name,
            artistName: artistName,
            artists: loadRelations
                ? [CassetteArtistEntity(
                    id: Self.artistIdentity(album: album, serverId: serverId),
                    name: artistName
                )]
                : [],
            universalProductCode: nil
        )
    }

    /// Prefers the server-assigned artist id; falls back to a name-derived id
    /// when the server omits it.
    private static func artistIdentity(album: AlbumID3, serverId: UUID) -> String {
        if let artistId = album.artistId, !artistId.isEmpty {
            return CassetteEntityID(serverId: serverId, localId: artistId).rawValue
        }
        return CassetteEntityID(
            serverId: serverId,
            localId: CassetteEntityDisplay.artistName(album.artist).lowercased()
        ).rawValue
    }
}
