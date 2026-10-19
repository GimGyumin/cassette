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
    private var mutationGeneration: UInt64 = 0
    private var pendingMutations = 0
    private struct MutationFlight { let id: UUID; let task: Task<Void, Error> }
    private var mutations: [String: MutationFlight] = [:]

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

    func isFavoriteInBackground(itemType: FavoriteType, itemId: String) async -> Bool {
        guard let sid = await MainActor.run(body: { serverState.activeServer?.id }) else { return false }
        let candidates = await mediaIdentityService.candidateRemoteIDsInBackground(
            for: itemId, serverId: sid, entityType: itemType.entityType
        )
        guard !Task.isCancelled else { return false }
        let type = itemType.rawValue
        var descriptor = FetchDescriptor<FavoriteRecord>(predicate: #Predicate {
            $0.serverId == sid && $0.itemType == type && candidates.contains($0.itemId)
        })
        descriptor.fetchLimit = 1
        return (try? ModelContext(modelContainer).fetch(descriptor).isEmpty) == false
    }

    func star(itemType: FavoriteType, itemId: String) async throws {
        try await mutate(itemType: itemType, itemId: itemId, starred: true)
    }

    func unstar(itemType: FavoriteType, itemId: String) async throws {
        try await mutate(itemType: itemType, itemId: itemId, starred: false)
    }

    private func mutate(itemType: FavoriteType, itemId: String, starred: Bool) async throws {
        mutationGeneration &+= 1
        pendingMutations += 1
        defer { pendingMutations -= 1; mutationGeneration &+= 1 }
        guard let sid = await MainActor.run(body: { serverState.activeServer?.id }) else { return }
        let identity = try await MainActor.run { try serverState.requestIdentity(for: sid) }
        let currentID = await MainActor.run {
            mediaIdentityService.resolveCurrentID(itemId, serverId: sid, entityType: itemType.entityType)
        }
        let key = "\(sid):\(itemType.rawValue):\(currentID)"
        let previous = mutations[key]?.task
        let id = UUID()
        let task = Task {
            // Preserve the order of consecutive taps, including when the earlier request fails.
            _ = await previous?.result
            try Task.checkCancellation()
            try await self.performMutation(itemType: itemType, currentID: currentID, identity: identity, starred: starred)
        }
        mutations[key] = MutationFlight(id: id, task: task)
        defer { if mutations[key]?.id == id { mutations[key] = nil } }
        try await task.value
    }

    private func performMutation(itemType: FavoriteType, currentID: String, identity: ServerRequestIdentity, starred: Bool) async throws {
        let sid = identity.serverID
        let candidates = await mediaIdentityService.candidateRemoteIDsInBackground(
            for: currentID, serverId: sid, entityType: itemType.entityType)
        try Task.checkCancellation()
        let type = itemType.rawValue
        // Model objects never escape this synchronous database operation.
        let previous: [(String, Date)] = try await MainActor.run {
            guard serverState.requestIsCurrent(identity), !Task.isCancelled else { throw CancellationError() }
            let context = ModelContext(modelContainer)
            let rows = try context.fetch(FetchDescriptor<FavoriteRecord>(predicate: #Predicate {
                $0.serverId == sid && $0.itemType == type && candidates.contains($0.itemId)
            }))
            let values = rows.map { ($0.itemId, $0.starredDate) }
            rows.forEach { context.delete($0) }
            if starred { context.insert(FavoriteRecord(itemType: itemType, itemId: currentID, starredDate: Date(), serverId: sid)) }
            try context.save()
            return values
        }
        do {
            let songs = itemType == .song ? [currentID] : []
            let albums = itemType == .album ? [currentID] : []
            let artists = itemType == .artist ? [currentID] : []
            if starred { try await libraryService.star(songIds: songs, albumIds: albums, artistIds: artists) }
            else { try await libraryService.unstar(songIds: songs, albumIds: albums, artistIds: artists) }
        } catch {
            // Account cleanup and rollback share MainActor: validation and the write cannot
            // straddle logout or resurrect a previous account after its records were cleared.
            try await MainActor.run {
                guard serverState.requestIsCurrent(identity), !Task.isCancelled else { throw CancellationError() }
                let context = ModelContext(modelContainer)
                let rows = try context.fetch(FetchDescriptor<FavoriteRecord>(predicate: #Predicate {
                    $0.serverId == sid && $0.itemType == type && candidates.contains($0.itemId)
                }))
                rows.forEach { context.delete($0) }
                for (item, date) in previous {
                    context.insert(FavoriteRecord(itemType: itemType, itemId: item, starredDate: date, serverId: sid))
                }
                try context.save()
            }
            throw error
        }
        guard await MainActor.run(body: { serverState.requestIsCurrent(identity) }) else { throw CancellationError() }
        await MainActor.run { NotificationCenter.default.post(name: .cassetteFavoritesChanged, object: nil) }
    }

    // MARK: - Sync

    func syncFromServer() async throws {
        guard pendingMutations == 0 else { return }
        let generation = mutationGeneration
        guard let sid = await MainActor.run(body: { serverState.activeServer?.id }) else { return }
        let identity = try await MainActor.run { try serverState.requestIdentity(for: sid) }
        let starred = try await libraryService.getStarred2()
        let incoming: [(FavoriteType, String)] =
            (starred.song ?? []).map { (.song, $0.id) }
            + (starred.album ?? []).map { (.album, $0.id) }
            + (starred.artist ?? []).map { (.artist, $0.id) }
        var resolved: [(FavoriteType, String, [String])] = []
        for (type, remoteID) in incoming {
            try Task.checkCancellation()
            let candidates = await mediaIdentityService.candidateRemoteIDsInBackground(
                for: remoteID, serverId: sid, entityType: type.entityType)
            resolved.append((type, remoteID, candidates))
        }
        guard generation == mutationGeneration, pendingMutations == 0, !Task.isCancelled else { return }
        let resolvedRecords = resolved
        try await MainActor.run {
            guard serverState.requestIsCurrent(identity), !Task.isCancelled else { throw CancellationError() }
            let context = ModelContext(modelContainer)
            let existing = try context.fetch(FetchDescriptor<FavoriteRecord>(predicate: #Predicate { $0.serverId == sid }))
            let byKey = Dictionary(existing.map { ("\($0.itemType):\($0.itemId)", $0) }, uniquingKeysWith: { first, _ in first })
            var retained = Set<String>()
            for (type, remoteID, candidates) in resolvedRecords {
                if let record = candidates.lazy.compactMap({ byKey["\(type.rawValue):\($0)"] }).first {
                    retained.insert(record.id)
                } else {
                    let record = FavoriteRecord(itemType: type, itemId: remoteID, starredDate: Date(), serverId: sid)
                    context.insert(record)
                    retained.insert(record.id)
                }
            }
            existing.filter { !retained.contains($0.id) }.forEach { context.delete($0) }
            try context.save()
        }
        await MainActor.run { NotificationCenter.default.post(name: .cassetteFavoritesChanged, object: nil) }
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
