// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import AppIntents
import Foundation

/// Resolves `CassettePlaylistEntity` values for the system.
@available(iOS 27.0, macOS 27.0, *)
struct CassettePlaylistQuery: EntityQuery {
    func entities(for identifiers: [CassettePlaylistEntity.ID]) async throws -> [CassettePlaylistEntity] {
        await SiriBridge.waitUntilReady()
        guard let catalog = await SiriBridge.catalogProvider?() else { return [] }
        var playlists: [CassettePlaylistEntity] = []
        playlists.reserveCapacity(identifiers.count)
        for rawIdentifier in identifiers {
            guard let identifier = CassetteEntityID(rawValue: rawIdentifier) else { continue }
            if let playlist = await catalog.playlist(id: identifier) {
                playlists.append(playlist)
            }
        }
        return playlists
    }

    func suggestedEntities() async throws -> [CassettePlaylistEntity] {
        await SiriBridge.waitUntilReady()
        guard let catalog = await SiriBridge.catalogProvider?() else { return [] }
        return await catalog.playlists(matching: "", limit: 25)
    }
}

@available(iOS 27.0, macOS 27.0, *)
extension CassettePlaylistQuery: EntityStringQuery {
    func entities(matching string: String) async throws -> [CassettePlaylistEntity] {
        await SiriBridge.waitUntilReady()
        guard let catalog = await SiriBridge.catalogProvider?() else { return [] }
        return await catalog.playlists(matching: string, limit: 25)
    }
}
