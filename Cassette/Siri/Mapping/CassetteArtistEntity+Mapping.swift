// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import SwiftSonic

/// Constructors for `CassetteArtistEntity`.
///
/// Kept in an extension (not the entity type) so the schema macro owns the
/// memberwise init. Schema properties are wrapped by the macro, so they must be
/// assigned with implicit self (`name = …`, not `self.name = …`) — Swift then
/// initializes the backing storage directly instead of going through the setter.
@available(iOS 27.0, macOS 27.0, *)
extension CassetteArtistEntity {
    init(id entityID: String, name artistName: String) {
        id = entityID
        name = artistName
    }

    /// Name-only artist, used for inline credits where the server gave no artist id.
    init(serverId: UUID, name artistName: String) {
        self.init(
            id: CassetteEntityID(serverId: serverId, localId: artistName.lowercased()).rawValue,
            name: artistName
        )
    }
}

@available(iOS 27.0, macOS 27.0, *)
extension CassetteArtistEntity {
    init(artist: ArtistID3, serverId: UUID) {
        self.init(
            id: CassetteEntityID(serverId: serverId, localId: artist.id).rawValue,
            name: artist.name
        )
    }
}
