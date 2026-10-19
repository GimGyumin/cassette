// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import SwiftData
import SwiftSonic
import OSLog

actor PlaylistService: PlaylistServiceProtocol {
    private let serverService: any ServerServiceProtocol
    private let modelContainer: ModelContainer
    private let downloadService: DownloadService
    private var cachedClient: SwiftSonicClient?
    private var cachedServerId: UUID?
    private var cachedIdentity: ServerRequestIdentity?
    private var contentRevision: UInt64 = 0

    private var listCache: [Playlist]?
    private var detailCache: [String: PlaylistWithSongs] = [:]

    init(serverService: any ServerServiceProtocol, modelContainer: ModelContainer, downloadService: DownloadService) {
        self.serverService = serverService
        self.modelContainer = modelContainer
        self.downloadService = downloadService
    }

    // MARK: - Client

    private func client() async throws -> (SwiftSonicClient, ServerRequestIdentity) {
        guard let activeID = await MainActor.run(body: { serverService.state.activeServer?.id }) else {
            throw CassetteError.serverNotConfigured
        }
        let identity = try await MainActor.run { try serverService.state.requestIdentity(for: activeID) }
        if let cached = cachedClient, cachedIdentity == identity { return (cached, identity) }
        let fresh = try await serverService.makeSwiftSonicClient()
        try await requireIdentity(identity)
        contentRevision &+= 1
        listCache = nil
        detailCache = [:]
        cachedClient = fresh
        cachedServerId = identity.serverID
        cachedIdentity = identity
        return (fresh, identity)
    }

    func invalidateClientCache() async {
        contentRevision &+= 1
        cachedClient = nil
        cachedIdentity = nil
        cachedServerId = nil
        listCache = nil
        detailCache = [:]
    }

    // MARK: - Read

    func listPlaylists() async throws -> [Playlist] {
        let (client, identity) = try await client()
        let revision = contentRevision
        if let cached = listCache { return cached }
        let playlists = try await client.getPlaylists()
        try await requireIdentity(identity)
        guard revision == contentRevision else { throw CancellationError() }
        listCache = playlists
        return playlists
    }

    func getPlaylist(id: String) async throws -> PlaylistWithSongs {
        let (client, identity) = try await client()
        let revision = contentRevision
        if let cached = detailCache[id] { return cached }
        let playlist = try await client.getPlaylist(id: id)
        try await requireIdentity(identity)
        guard revision == contentRevision else { throw CancellationError() }
        detailCache[id] = playlist
        return playlist
    }

    // MARK: - Create / Delete

    @discardableResult
    func createPlaylist(name: String, description: String?) async throws -> PlaylistWithSongs {
        let (client, identity) = try await client()
        contentRevision &+= 1
        let result = try await client.createPlaylist(name: name)
        try await requireIdentity(identity)
        if let desc = description, !desc.isEmpty {
            try await client.updatePlaylist(id: result.id, comment: desc)
            try await requireIdentity(identity)
        }
        contentRevision &+= 1
        listCache = nil
        detailCache[result.id] = description.map { copying(result, comment: $0) } ?? result
        return result
    }

    func deletePlaylist(id: String, purgeDownloads: Bool) async throws {
        let (client, identity) = try await client()
        contentRevision &+= 1
        let revision = contentRevision
        let previousList = listCache
        let previousDetail = detailCache[id]
        listCache?.removeAll { $0.id == id }
        detailCache[id] = nil
        do {
            try await client.deletePlaylist(id: id)
            try await requireIdentity(identity)
        } catch {
            guard Self.isNotFound(error) else {
                if revision == contentRevision,
                   await MainActor.run(body: { serverService.state.requestIsCurrent(identity) }) {
                    listCache = previousList
                    detailCache[id] = previousDetail
                }
                throw error
            }
            try await requireIdentity(identity)
        }
        contentRevision &+= 1
        listCache = nil
        detailCache[id] = nil
        if purgeDownloads {
            // The original account owns every local side effect, including after an await.
            try await downloadService.remove(playlistId: id, serverId: identity.serverID)
            await MainActor.run {
                PlaylistCoverStore(modelContainer: modelContainer).remove(playlistId: id, serverId: identity.serverID)
            }
        }
    }

    /// Strictly a "not found" server response (Subsonic error code 70 or HTTP 404) — makes deletePlaylist
    /// idempotent for an already-removed playlist. Deliberately NOT a broad catch.
    private nonisolated static func isNotFound(_ error: Error) -> Bool {
        guard let sse = error as? SwiftSonicError else { return false }
        switch sse {
        case .api(let apiError) where apiError.code == .notFound:
            return true
        case .httpError(let statusCode, _, _) where statusCode == 404:
            return true
        default:
            return false
        }
    }

    // MARK: - Metadata updates

    func renamePlaylist(id: String, newName: String) async throws {
        let (client, identity) = try await client()
        contentRevision &+= 1
        let revision = contentRevision
        let previousList = listCache
        let previousDetail = detailCache[id]
        if let idx = listCache?.firstIndex(where: { $0.id == id }), let p = listCache?[idx] {
            listCache?[idx] = copying(p, name: newName)
        }
        if let p = detailCache[id] {
            detailCache[id] = copying(p, name: newName)
        }
        do {
            try await client.updatePlaylist(id: id, name: newName)
            try await requireIdentity(identity)
            contentRevision &+= 1
            Logger.playlist.info("Renamed playlist id=\(id, privacy: .public) to '\(newName, privacy: .private)'")
        } catch {
            if revision == contentRevision,
               await MainActor.run(body: { serverService.state.requestIsCurrent(identity) }) {
                listCache = previousList
                detailCache[id] = previousDetail
            }
            throw error
        }
    }

    func updateDescription(id: String, description: String) async throws {
        let (client, identity) = try await client()
        contentRevision &+= 1
        let revision = contentRevision
        let previousDetail = detailCache[id]
        if let p = detailCache[id] {
            detailCache[id] = copying(p, comment: description)
        }
        do {
            try await client.updatePlaylist(id: id, comment: description)
            try await requireIdentity(identity)
            contentRevision &+= 1
            Logger.playlist.info("Updated description for playlist id=\(id, privacy: .public)")
        } catch {
            if revision == contentRevision,
               await MainActor.run(body: { serverService.state.requestIsCurrent(identity) }) {
                detailCache[id] = previousDetail
            }
            throw error
        }
    }

    func updateVisibility(id: String, isPublic: Bool) async throws {
        let (client, identity) = try await client()
        contentRevision &+= 1
        let revision = contentRevision
        let previousList = listCache
        let previousDetail = detailCache[id]
        if let idx = listCache?.firstIndex(where: { $0.id == id }), let playlist = listCache?[idx] {
            listCache?[idx] = copying(playlist, isPublic: isPublic)
        }
        if let playlist = detailCache[id] {
            detailCache[id] = copying(playlist, isPublic: isPublic)
        }
        do {
            try await client.updatePlaylist(id: id, isPublic: isPublic)
            try await requireIdentity(identity)
            contentRevision &+= 1
            Logger.playlist.info("Updated visibility for playlist id=\(id, privacy: .public) public=\(isPublic, privacy: .public)")
        } catch {
            if revision == contentRevision,
               await MainActor.run(body: { serverService.state.requestIsCurrent(identity) }) {
                listCache = previousList
                detailCache[id] = previousDetail
            }
            throw error
        }
    }

    // MARK: - Track mutations

    func addTracks(playlistId: String, songs: [Song]) async throws {
        let (client, identity) = try await client()
        let serverID = identity.serverID
        contentRevision &+= 1
        let revision = contentRevision
        let previousDetail = detailCache[playlistId]
        let previousList = listCache
        let addedDuration = songs.reduce(0) { $0 + ($1.duration ?? 0) }
        if let p = detailCache[playlistId] {
            detailCache[playlistId] = copying(p,
                songCountDelta: songs.count,
                durationDelta: addedDuration,
                entry: (p.entry ?? []) + songs
            )
        }
        if let idx = listCache?.firstIndex(where: { $0.id == playlistId }), let p = listCache?[idx] {
            listCache?[idx] = copying(p, songCountDelta: songs.count, durationDelta: addedDuration)
        }
        do {
            try await client.updatePlaylist(id: playlistId, songIdsToAdd: songs.map(\.id))
            try await requireIdentity(identity)
            contentRevision &+= 1
            Logger.playlist.info("Added \(songs.count, privacy: .public) track(s) to playlist id=\(playlistId, privacy: .public)")
            await syncDownloadedPlaylistAfterAdd(playlistId: playlistId, serverID: serverID, addedSongs: songs)
        } catch {
            if revision == contentRevision,
               await MainActor.run(body: { serverService.state.requestIsCurrent(identity) }) {
                detailCache[playlistId] = previousDetail
                listCache = previousList
            }
            throw error
        }
    }

    func removeTracks(playlistId: String, indices: [Int]) async throws {
        let (client, identity) = try await client()
        let serverID = identity.serverID
        let playlist = try await getPlaylist(id: playlistId)
        try await requireIdentity(identity)
        let entry = playlist.entry ?? []
        let indexSet = Set(indices)
        guard indexSet.allSatisfy({ entry.indices.contains($0) }) else { throw URLError(.badURL) }
        let remaining = entry.enumerated().filter { !indexSet.contains($0.offset) }.map(\.element)
        contentRevision &+= 1
        try await client.updatePlaylist(id: playlistId, songIndexesToRemove: indexSet.sorted())
        try await requireIdentity(identity)
        contentRevision &+= 1
        let duration = indexSet.reduce(0) { $0 + (entry[$1].duration ?? 0) }
        detailCache[playlistId] = copying(playlist, songCountDelta: -indexSet.count,
            durationDelta: -duration, entry: remaining)
        listCache = nil
        await syncDownloadedPlaylistOrder(playlistId: playlistId, serverID: serverID, orderedIDs: remaining.map(\.id))
    }

    func reorderTracks(playlistId: String, orderedSongIds: [String]) async throws {
        let (client, identity) = try await client()
        let serverID = identity.serverID
        contentRevision &+= 1
        try await client.createPlaylist(playlistId: playlistId, songIds: orderedSongIds)
        try await requireIdentity(identity)
        contentRevision &+= 1
        if let p = detailCache[playlistId], let entry = p.entry {
            let byID = Dictionary(entry.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            detailCache[playlistId] = copying(p, entry: orderedSongIds.compactMap { byID[$0] })
        }
        await syncDownloadedPlaylistOrder(playlistId: playlistId, serverID: serverID, orderedIDs: orderedSongIds)
    }

    private func requireIdentity(_ identity: ServerRequestIdentity) async throws {
        try Task.checkCancellation()
        guard await MainActor.run(body: { serverService.state.requestIsCurrent(identity) }) else { throw CancellationError() }
    }

    private func requireServer(_ sid: UUID?) async throws {
        try Task.checkCancellation()
        guard let sid, await MainActor.run(body: {
            serverService.state.activeServer?.id == sid && !serverService.state.isSigningOut
        }) else { throw CancellationError() }
    }

    // MARK: - Offline sync

    private func syncDownloadedPlaylistAfterAdd(playlistId: String, serverID: UUID, addedSongs: [Song]) async {
        let generation = await downloadService.currentDownloadGeneration()
        let updated = await MainActor.run { () -> Bool in
            guard serverService.state.activeServer?.id == serverID, !Task.isCancelled else { return false }
            let context = modelContainer.mainContext
            let pid = playlistId
            let descriptor = FetchDescriptor<DownloadedPlaylist>(predicate: #Predicate {
                $0.playlistId == pid && $0.serverId == serverID
            })
            guard let record = try? context.fetch(descriptor).first else { return false }
            record.songIds.append(contentsOf: addedSongs.map(\.id))
            record.totalTracksCount += addedSongs.count
            do { try context.save(); return true } catch { return false }
        }
        guard updated else { return }
        Task { [weak self] in await self?.downloadSongsBounded(addedSongs, serverId: serverID, generation: generation) }
    }

    private func syncDownloadedPlaylistOrder(playlistId: String, serverID: UUID, orderedIDs: [String]) async {
        await MainActor.run {
            guard serverService.state.activeServer?.id == serverID, !Task.isCancelled else { return }
            let context = modelContainer.mainContext
            let pid = playlistId
            let descriptor = FetchDescriptor<DownloadedPlaylist>(predicate: #Predicate {
                $0.playlistId == pid && $0.serverId == serverID
            })
            guard let record = try? context.fetch(descriptor).first else { return }
            // Server indices identify occurrences. Preserve surviving duplicates and their order.
            let retained = Set(record.songIds)
            record.songIds = orderedIDs.filter { retained.contains($0) }
            record.tracksCount = min(record.tracksCount, record.songIds.count)
            record.totalTracksCount = orderedIDs.count
            try? context.save()
        }
    }

    func retryMissingPlaylistDownloads() async {
        let generation = await downloadService.currentDownloadGeneration()
        // Only the active server can provide authoritative playlist contents. Querying records
        // from other servers through the active client wasted requests and could never pass the
        // DownloadService server-identity guard.
        guard let activeServerId = await MainActor.run(body: {
            serverService.state.activeServer?.id
        }) else { return }

        let records = await MainActor.run { () -> [(playlistId: String, serverId: UUID, songIds: [String])] in
            let context = modelContainer.mainContext
            let sid = activeServerId
            let descriptor = FetchDescriptor<DownloadedPlaylist>(
                predicate: #Predicate { $0.serverId == sid }
            )
            guard let fetched = try? context.fetch(descriptor) else { return [] }
            return fetched
                .filter { !$0.songIds.isEmpty }
                .map { (playlistId: $0.playlistId, serverId: $0.serverId, songIds: $0.songIds) }
        }
        guard !records.isEmpty else { return }

        // Every record is scoped to one server, so a single SwiftData lookup is enough.
        let downloadedIds = await downloadService.downloadedSongIds(serverId: activeServerId)
        var queuedSongIds = Set<String>()
        var songsToDownload: [Song] = []

        for record in records {
            let missingIds = record.songIds.filter { !downloadedIds.contains($0) }

            guard !missingIds.isEmpty else { continue }

            Logger.playlist.info("Retrying \(missingIds.count, privacy: .public) missing track(s) for playlist '\(record.playlistId, privacy: .public)'")

            guard let (client, identity) = try? await client(), identity.serverID == activeServerId else { return }
            guard let playlist = try? await client.getPlaylist(id: record.playlistId),
                  (try? await requireIdentity(identity)) != nil else {
                Logger.playlist.warning("Failed to fetch playlist '\(record.playlistId, privacy: .public)' for retry — skipping.")
                continue
            }

            let missingIdSet = Set(missingIds)
            for song in playlist.entry ?? []
            where missingIdSet.contains(song.id) && queuedSongIds.insert(song.id).inserted {
                songsToDownload.append(song)
            }
        }

        guard !songsToDownload.isEmpty else { return }
        await downloadSongsBounded(songsToDownload, serverId: activeServerId, generation: generation)
    }

    /// Bounds repair/add downloads so large playlists do not create one URLSession task per song
    /// at once. DownloadService still coalesces duplicate track requests across other callers.
    private func downloadSongsBounded(_ songs: [Song], serverId: UUID, generation: UInt64) async {
        _ = try? await downloadService.downloadSongs(songs, serverId: serverId, generation: generation)
    }

    // MARK: - Copy helpers

    private func copying(
        _ p: Playlist,
        name: String? = nil,
        comment: String? = nil,
        isPublic: Bool? = nil,
        songCountDelta: Int = 0,
        durationDelta: Int = 0
    ) -> Playlist {
        Playlist(
            id: p.id,
            name: name ?? p.name,
            songCount: max(0, p.songCount + songCountDelta),
            duration: max(0, p.duration + durationDelta),
            comment: comment ?? p.comment,
            owner: p.owner,
            isPublic: isPublic ?? p.isPublic,
            created: p.created,
            changed: p.changed,
            coverArt: p.coverArt
        )
    }

    private func copying(
        _ p: PlaylistWithSongs,
        name: String? = nil,
        comment: String? = nil,
        isPublic: Bool? = nil,
        songCountDelta: Int = 0,
        durationDelta: Int = 0,
        entry: [Song]? = nil
    ) -> PlaylistWithSongs {
        PlaylistWithSongs(
            id: p.id,
            name: name ?? p.name,
            songCount: max(0, p.songCount + songCountDelta),
            duration: max(0, p.duration + durationDelta),
            comment: comment ?? p.comment,
            owner: p.owner,
            isPublic: isPublic ?? p.isPublic,
            created: p.created,
            changed: p.changed,
            coverArt: p.coverArt,
            entry: entry ?? p.entry
        )
    }
}
