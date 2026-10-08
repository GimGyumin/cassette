// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import SwiftData
import SwiftSonic
import OSLog

actor FavoritesService: FavoritesServiceProtocol {
    private let libraryService: any LibraryServiceProtocol
    private nonisolated let serverState: ServerState
    private nonisolated let mediaIdentityService: MediaIdentityService
    nonisolated let modelContainer: ModelContainer
    private lazy var backgroundContext: ModelContext = ModelContext(modelContainer)

    init(
        libraryService: any LibraryServiceProtocol,
        serverState: ServerState,
        modelContainer: ModelContainer,
        mediaIdentityService: MediaIdentityService
    ) {
        self.libraryService = libraryService
        self.serverState = serverState
        self.modelContainer = modelContainer
        self.mediaIdentityService = mediaIdentityService
    }

    // MARK: - Query

    // Safe: only called from @MainActor views; assumeIsolated matches all real call sites.
    nonisolated func isFavorite(itemType: FavoriteType, itemId: String) -> Bool {
        return MainActor.assumeIsolated {
            guard let serverID = serverState.activeServer?.id else { return false }
            let candidates = mediaIdentityService.candidateRemoteIDs(
                for: itemId,
                serverId: serverID,
                entityType: itemType.entityType
            )
            let sid = serverID
            let type = itemType.rawValue
            var descriptor = FetchDescriptor<FavoriteRecord>(predicate: #Predicate {
                $0.serverId == sid && $0.itemType == type && candidates.contains($0.itemId)
            })
            descriptor.fetchLimit = 1
            return (try? modelContainer.mainContext.fetch(descriptor).isEmpty) == false
        }
    }

    // MARK: - Star

    func star(itemType: FavoriteType, itemId: String) async throws {
        guard let serverId = await MainActor.run(body: { serverState.activeServer?.id }) else { return }
        let currentID = await MainActor.run {
            mediaIdentityService.resolveCurrentID(itemId, serverId: serverId, entityType: itemType.entityType)
        }

        let type = itemType.rawValue
        let existing = try backgroundContext.fetch(FetchDescriptor<FavoriteRecord>(predicate: #Predicate {
            $0.serverId == serverId && $0.itemType == type
        }))
        let candidateIDs = await MainActor.run {
            Set(mediaIdentityService.candidateRemoteIDs(for: currentID, serverId: serverId, entityType: itemType.entityType))
        }
        if existing.contains(where: { candidateIDs.contains($0.itemId) }) { return }

        let record = FavoriteRecord(itemType: itemType, itemId: currentID, starredDate: Date(), serverId: serverId)
        backgroundContext.insert(record)
        do { try backgroundContext.save() }
        catch { backgroundContext.rollback(); throw error }

        do {
            switch itemType {
            case .song:   try await libraryService.star(songIds: [currentID], albumIds: [], artistIds: [])
            case .album:  try await libraryService.star(songIds: [], albumIds: [currentID], artistIds: [])
            case .artist: try await libraryService.star(songIds: [], albumIds: [], artistIds: [currentID])
            }
            Logger.favorites.info("Starred \(itemType.rawValue, privacy: .public) \(itemId, privacy: .public)")
            NotificationCenter.default.post(name: .cassetteFavoritesChanged, object: nil)
        } catch {
            backgroundContext.delete(record)
            try? backgroundContext.save()
            throw error
        }
    }

    // MARK: - Unstar

    func unstar(itemType: FavoriteType, itemId: String) async throws {
        guard let serverID = await MainActor.run(body: { serverState.activeServer?.id }) else { return }
        let currentID = await MainActor.run {
            mediaIdentityService.resolveCurrentID(itemId, serverId: serverID, entityType: itemType.entityType)
        }
        let candidates = await MainActor.run {
            Set(mediaIdentityService.candidateRemoteIDs(for: currentID, serverId: serverID, entityType: itemType.entityType))
        }
        let sid = serverID
        let type = itemType.rawValue
        let records = try backgroundContext.fetch(FetchDescriptor<FavoriteRecord>(predicate: #Predicate {
            $0.serverId == sid && $0.itemType == type
        }))
        guard let record = records.first(where: { candidates.contains($0.itemId) }) else { return }

        let capturedServerId = record.serverId
        let capturedDate = record.starredDate
        backgroundContext.delete(record)
        do { try backgroundContext.save() }
        catch { backgroundContext.rollback(); throw error }

        do {
            switch itemType {
            case .song:   try await libraryService.unstar(songIds: [currentID], albumIds: [], artistIds: [])
            case .album:  try await libraryService.unstar(songIds: [], albumIds: [currentID], artistIds: [])
            case .artist: try await libraryService.unstar(songIds: [], albumIds: [], artistIds: [currentID])
            }
            Logger.favorites.info("Unstarred \(itemType.rawValue, privacy: .public) \(itemId, privacy: .public)")
            NotificationCenter.default.post(name: .cassetteFavoritesChanged, object: nil)
        } catch {
            let restored = FavoriteRecord(itemType: itemType, itemId: itemId, starredDate: capturedDate, serverId: capturedServerId)
            backgroundContext.insert(restored)
            try? backgroundContext.save()
            throw error
        }
    }

    // MARK: - Sync

    func syncFromServer() async throws {
        guard let serverId = await MainActor.run(body: { serverState.activeServer?.id }) else { return }

        let starred = try await libraryService.getStarred2()

        let descriptor = FetchDescriptor<FavoriteRecord>(
            predicate: #Predicate<FavoriteRecord> { $0.serverId == serverId }
        )
        let existing = (try? backgroundContext.fetch(descriptor)) ?? []
        var retainedRecordIDs = Set<String>()
        var added = 0
        var unchanged = 0
        let incoming: [(FavoriteType, String)] =
            (starred.song ?? []).map { (.song, $0.id) }
            + (starred.album ?? []).map { (.album, $0.id) }
            + (starred.artist ?? []).map { (.artist, $0.id) }

        for (type, remoteID) in incoming {
            let candidateIDs = await MainActor.run {
                Set(mediaIdentityService.candidateRemoteIDs(
                    for: remoteID,
                    serverId: serverId,
                    entityType: type.entityType
                ))
            }
            if let record = existing.first(where: {
                $0.itemType == type.rawValue && candidateIDs.contains($0.itemId)
            }) {
                retainedRecordIDs.insert(record.id)
                unchanged += 1
            } else {
                let record = FavoriteRecord(
                    itemType: type,
                    itemId: remoteID,
                    starredDate: Date(),
                    serverId: serverId
                )
                backgroundContext.insert(record)
                retainedRecordIDs.insert(record.id)
                added += 1
            }
        }

        let toRemove = existing.filter { !retainedRecordIDs.contains($0.id) }
        toRemove.forEach { backgroundContext.delete($0) }

        try? backgroundContext.save()
        Logger.favorites.info("Favorites synced: \(added, privacy: .public) added, \(toRemove.count, privacy: .public) removed, \(unchanged, privacy: .public) unchanged")
        NotificationCenter.default.post(name: .cassetteFavoritesChanged, object: nil)
    }
}

private extension FavoriteType {
    var entityType: RemoteMediaEntityType {
        switch self {
        case .song: .song
        case .album: .album
        case .artist: .artist
        }
    }
}
