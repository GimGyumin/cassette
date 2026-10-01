// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import AppIntents
import Foundation

/// Resolves `CassetteAlbumEntity` values for the system.
@available(iOS 27.0, macOS 27.0, *)
struct CassetteAlbumQuery: EntityQuery {
    func entities(for identifiers: [CassetteAlbumEntity.ID]) async throws -> [CassetteAlbumEntity] {
        await SiriBridge.waitUntilReady()
        guard let catalog = await SiriBridge.catalogProvider?() else { return [] }
        var albums: [CassetteAlbumEntity] = []
        albums.reserveCapacity(identifiers.count)
        for rawIdentifier in identifiers {
            guard let identifier = CassetteEntityID(rawValue: rawIdentifier) else { continue }
            if let album = await catalog.album(id: identifier) {
                albums.append(album)
            }
        }
        return albums
    }

    func suggestedEntities() async throws -> [CassetteAlbumEntity] {
        await SiriBridge.waitUntilReady()
        guard let catalog = await SiriBridge.catalogProvider?() else { return [] }
        return await catalog.albums(matching: "", limit: 25)
    }
}

@available(iOS 27.0, macOS 27.0, *)
extension CassetteAlbumQuery: EntityStringQuery {
    func entities(matching string: String) async throws -> [CassetteAlbumEntity] {
        await SiriBridge.waitUntilReady()
        guard let catalog = await SiriBridge.catalogProvider?() else { return [] }
        return await catalog.albums(matching: string, limit: 25)
    }
}
