// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import AppIntents
import CoreSpotlight
import Foundation

/// The CoreSpotlight index that hosts Cassette's AppEntities.
enum CassetteSpotlight {
    static let indexName = "Cassette"

    // v2 stores song album/artist relations, allowing Siri to distinguish an album
    // recording from a same-titled single or remix. Bumping the marker forces one
    // bounded reindex for existing installations after upgrading.
    private static let warmupKeyPrefix = "cassette.siri.spotlight.warmed.v2."

    static func isWarm(for serverId: UUID) -> Bool {
        UserDefaults.standard.bool(forKey: warmupKeyPrefix + serverId.uuidString)
    }

    static func markWarm(for serverId: UUID) {
        UserDefaults.standard.set(true, forKey: warmupKeyPrefix + serverId.uuidString)
    }

    static func resetWarmState(for serverId: UUID) {
        UserDefaults.standard.removeObject(forKey: warmupKeyPrefix + serverId.uuidString)
    }
}

// MARK: - IndexedEntity
//
// Conformance is declared in the primary declaration of each entity
// (`struct CassetteSongEntity: IndexedEntity`, etc.) so that `_IntentValue`
// (via `IndexedEntity` → `AppEntity` → `AppValue`) is established eagerly at
// the declaration site. Entity-typed schema properties (`album`, `artists`,
// `composers`) depend on this; macro-generated conformances are order-sensitive
// under whole-module compilation, so keeping `IndexedEntity` in the declaration
// avoids flaky “requires that 'Cassette…Entity' conform to '_IntentValue'” errors.

// MARK: - IndexedEntityQuery
//
// Called by Spotlight to rebuild the index (corrupt-index recovery, manual
// reindex). Reindexing is server-bounded (never a full-library scan at launch).

@available(iOS 27.0, macOS 27.0, *)
extension CassetteSongQuery: IndexedEntityQuery {
    func reindexEntities(
        for identifiers: [CassetteSongEntity.ID],
        indexDescription: CSSearchableIndexDescription
    ) async throws {
        await SiriBridge.waitUntilReady()
        guard let catalog = await SiriBridge.catalogProvider?() else { return }
        var entities: [CassetteSongEntity] = []
        for rawIdentifier in identifiers {
            guard let id = CassetteEntityID(rawValue: rawIdentifier),
                  let song = await catalog.song(id: id) else { continue }
            entities.append(song)
        }
        try await CSSearchableIndex(name: CassetteSpotlight.indexName).indexAppEntities(entities)
    }

    func reindexAllEntities(indexDescription: CSSearchableIndexDescription) async throws {
        await SiriBridge.waitUntilReady()
        guard let catalog = await SiriBridge.catalogProvider?() else { return }
        let entities = await catalog.allSongs(limit: 1_000)
        try await CSSearchableIndex(name: CassetteSpotlight.indexName).indexAppEntities(entities)
    }
}

@available(iOS 27.0, macOS 27.0, *)
extension CassetteAlbumQuery: IndexedEntityQuery {
    func reindexEntities(
        for identifiers: [CassetteAlbumEntity.ID],
        indexDescription: CSSearchableIndexDescription
    ) async throws {
        await SiriBridge.waitUntilReady()
        guard let catalog = await SiriBridge.catalogProvider?() else { return }
        var entities: [CassetteAlbumEntity] = []
        for rawIdentifier in identifiers {
            guard let id = CassetteEntityID(rawValue: rawIdentifier),
                  let album = await catalog.album(id: id) else { continue }
            entities.append(album)
        }
        try await CSSearchableIndex(name: CassetteSpotlight.indexName).indexAppEntities(entities)
    }

    func reindexAllEntities(indexDescription: CSSearchableIndexDescription) async throws {
        await SiriBridge.waitUntilReady()
        guard let catalog = await SiriBridge.catalogProvider?() else { return }
        let entities = await catalog.allAlbums(limit: 1_000)
        try await CSSearchableIndex(name: CassetteSpotlight.indexName).indexAppEntities(entities)
    }
}

@available(iOS 27.0, macOS 27.0, *)
extension CassetteArtistQuery: IndexedEntityQuery {
    func reindexEntities(
        for identifiers: [CassetteArtistEntity.ID],
        indexDescription: CSSearchableIndexDescription
    ) async throws {
        await SiriBridge.waitUntilReady()
        guard let catalog = await SiriBridge.catalogProvider?() else { return }
        var entities: [CassetteArtistEntity] = []
        for rawIdentifier in identifiers {
            guard let id = CassetteEntityID(rawValue: rawIdentifier),
                  let artist = await catalog.artist(id: id) else { continue }
            entities.append(artist)
        }
        try await CSSearchableIndex(name: CassetteSpotlight.indexName).indexAppEntities(entities)
    }

    func reindexAllEntities(indexDescription: CSSearchableIndexDescription) async throws {
        await SiriBridge.waitUntilReady()
        guard let catalog = await SiriBridge.catalogProvider?() else { return }
        let entities = await catalog.allArtists(limit: 1_000)
        try await CSSearchableIndex(name: CassetteSpotlight.indexName).indexAppEntities(entities)
    }
}

@available(iOS 27.0, macOS 27.0, *)
extension CassettePlaylistQuery: IndexedEntityQuery {
    func reindexEntities(
        for identifiers: [CassettePlaylistEntity.ID],
        indexDescription: CSSearchableIndexDescription
    ) async throws {
        await SiriBridge.waitUntilReady()
        guard let catalog = await SiriBridge.catalogProvider?() else { return }
        var entities: [CassettePlaylistEntity] = []
        for rawIdentifier in identifiers {
            guard let id = CassetteEntityID(rawValue: rawIdentifier),
                  let playlist = await catalog.playlist(id: id) else { continue }
            entities.append(playlist)
        }
        try await CSSearchableIndex(name: CassetteSpotlight.indexName).indexAppEntities(entities)
    }

    func reindexAllEntities(indexDescription: CSSearchableIndexDescription) async throws {
        await SiriBridge.waitUntilReady()
        guard let catalog = await SiriBridge.catalogProvider?() else { return }
        let entities = await catalog.allPlaylists(limit: 1_000)
        try await CSSearchableIndex(name: CassetteSpotlight.indexName).indexAppEntities(entities)
    }
}
