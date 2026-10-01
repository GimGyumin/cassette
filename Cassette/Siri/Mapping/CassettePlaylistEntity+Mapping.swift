// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import SwiftSonic

/// Maps SwiftSonic's `Playlist` onto the `.audio.playlist` schema.
@available(iOS 27.0, macOS 27.0, *)
extension CassettePlaylistEntity {
    /// General-purpose internal constructor. Parameter names never shadow the
    /// schema properties, and the plain `trackCount` is assigned before the
    /// wrapped schema properties.
    init(
        id entityID: String,
        title playlistTitle: String,
        owner playlistOwner: CassettePlaylistOwner? = nil,
        createdByMe isMine: Bool? = nil,
        curatedForMe isCurated: Bool? = nil,
        trackCount count: Int = 0
    ) {
        id = entityID
        trackCount = count
        title = playlistTitle
        owner = playlistOwner
        createdByMe = isMine
        curatedForMe = isCurated
    }

    /// - Parameter isMine: `nil` when ownership can't be determined, rather than
    ///   guessing. Navidrome reports the owner as a username string, so callers
    ///   that can reach the active account may resolve it.
    init(playlist: Playlist, serverId: UUID, createdByMe isMine: Bool? = nil) {
        id = CassetteEntityID(serverId: serverId, localId: playlist.id).rawValue
        trackCount = playlist.songCount
        title = playlist.name
        owner = playlist.owner.map { CassettePlaylistOwner.name($0) }
        createdByMe = isMine
        curatedForMe = nil
    }
}
