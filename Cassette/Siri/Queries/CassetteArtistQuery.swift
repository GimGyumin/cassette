// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import AppIntents
import Foundation

/// Resolves `CassetteArtistEntity` values for the system.
@available(iOS 27.0, macOS 27.0, *)
struct CassetteArtistQuery: EntityQuery {
    func entities(for identifiers: [CassetteArtistEntity.ID]) async throws -> [CassetteArtistEntity] {
        await SiriBridge.waitUntilReady()
        guard let catalog = await SiriBridge.catalogProvider?() else { return [] }
        var artists: [CassetteArtistEntity] = []
        artists.reserveCapacity(identifiers.count)
        for rawIdentifier in identifiers {
            guard let identifier = CassetteEntityID(rawValue: rawIdentifier) else { continue }
            if let artist = await catalog.artist(id: identifier) {
                artists.append(artist)
            }
        }
        return artists
    }

    func suggestedEntities() async throws -> [CassetteArtistEntity] {
        await SiriBridge.waitUntilReady()
        guard let catalog = await SiriBridge.catalogProvider?() else { return [] }
        return await catalog.artists(matching: "", limit: 25)
    }
}

@available(iOS 27.0, macOS 27.0, *)
extension CassetteArtistQuery: EntityStringQuery {
    func entities(matching string: String) async throws -> [CassetteArtistEntity] {
        await SiriBridge.waitUntilReady()
        guard let catalog = await SiriBridge.catalogProvider?() else { return [] }
        return await catalog.artists(matching: string, limit: 25)
    }
}
