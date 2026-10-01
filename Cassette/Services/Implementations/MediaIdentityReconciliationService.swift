// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.

import Foundation
import OSLog
import SwiftData
import SwiftSonic

nonisolated struct DownloadIdentitySnapshot: Sendable, Equatable {
    let recordID: UUID
    let historicalID: String
    let currentRemoteID: String?
    let albumID: String?
    let artistID: String?
    let coverArtID: String?
    let title: String
    let artist: String?
    let album: String?
    let discNumber: Int?
    let trackNumber: Int?
    let durationSeconds: Int?
    let mediaPath: String?
    let musicBrainzID: String?
    let isrc: String?
}

nonisolated struct RemoteIdentityMatch: Sendable, Equatable {
    let songID: String
    let confidence: Double
    let source: RemoteIDVerificationSource
}

/// Pure matcher used by the migration and its regression tests. It intentionally refuses
/// title+artist-only matches; ties at the strongest available evidence remain unresolved.
nonisolated enum RemoteIdentityMatcher {
    static func match(download: DownloadIdentitySnapshot, candidates: [Song]) -> RemoteIdentityMatch? {
        let ranked = candidates.compactMap { song -> (Song, Int, RemoteIDVerificationSource)? in
            if let lhs = normalizedIdentifier(download.musicBrainzID),
               let rhs = normalizedIdentifier(song.musicBrainzId), lhs == rhs {
                return (song, 400, .externalIdentifier)
            }
            if let lhs = normalizedIdentifier(download.isrc),
               let rhs = normalizedIdentifier(song.isrc?.first), lhs == rhs {
                return (song, 390, .externalIdentifier)
            }
            if let lhs = normalizedPath(download.mediaPath),
               let rhs = normalizedPath(song.path), lhs == rhs {
                return (song, 300, .exactPath)
            }
            guard strictMetadataMatches(download: download, song: song) else { return nil }
            return (song, 200, .strictMetadata)
        }
        guard let bestScore = ranked.map(\.1).max() else { return nil }
        let best = ranked.filter { $0.1 == bestScore }
        guard best.count == 1, let value = best.first else { return nil }
        let confidence: Double = switch value.2 {
        case .externalIdentifier: 1
        case .exactPath: 0.99
        case .strictMetadata: 0.92
        case .serverResponse: 1
        case .userConfirmed: 1
        }
        return RemoteIdentityMatch(songID: value.0.id, confidence: confidence, source: value.2)
    }

    private static func strictMetadataMatches(download: DownloadIdentitySnapshot, song: Song) -> Bool {
        guard download.trackNumber != nil, download.durationSeconds != nil else { return false }
        guard normalized(download.title) == normalized(song.title),
              normalized(download.artist) == normalized(song.artist),
              normalized(download.album) == normalized(song.album),
              download.trackNumber == song.track else { return false }
        if let disc = download.discNumber, disc != song.discNumber { return false }
        guard let oldDuration = download.durationSeconds, let newDuration = song.duration,
              abs(oldDuration - newDuration) <= 2 else { return false }
        return true
    }

    private static func normalized(_ value: String?) -> String {
        (value ?? "")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedIdentifier(_ value: String?) -> String? {
        let result = normalized(value).lowercased()
        return result.isEmpty ? nil : result
    }

    private static func normalizedPath(_ value: String?) -> String? {
        guard let value else { return nil }
        let result = value.replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
            .precomposedStringWithCanonicalMapping
        return result.isEmpty ? nil : result
    }
}

/// Idempotently reconnects preserved downloads after a server changes remote IDs. Audio files
/// and historical keys are never renamed or deleted; only additive identity metadata is saved.
actor MediaIdentityReconciliationService {
    private let modelContainer: ModelContainer
    private let libraryService: any LibraryServiceProtocol
    private let identityService: MediaIdentityService
    private var inFlight: Task<Void, Never>?

    init(
        modelContainer: ModelContainer,
        libraryService: any LibraryServiceProtocol,
        identityService: MediaIdentityService
    ) {
        self.modelContainer = modelContainer
        self.libraryService = libraryService
        self.identityService = identityService
    }

    func reconcileDownloads(serverID: UUID) async {
        if let inFlight { await inFlight.value; return }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performReconciliation(serverID: serverID)
        }
        inFlight = task
        await task.value
        inFlight = nil
    }

    private func performReconciliation(serverID: UUID) async {
        let downloads = await snapshots(serverID: serverID)
        guard !downloads.isEmpty else { return }

        var catalog: [Song] = []
        var offset = 0
        let pageSize = 500
        do {
            while !Task.isCancelled {
                let page = try await libraryService.librarySongs(offset: offset, count: pageSize)
                guard !page.isEmpty else { break }
                catalog.append(contentsOf: page)
                if page.count < pageSize { break }
                offset += page.count
                await Task.yield()
            }
        } catch {
            Logger.server.warning("ID reconciliation deferred — catalog fetch failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        let catalogIDs = Set(catalog.map(\.id))
        for download in downloads where !Task.isCancelled {
            let resolved = await identityService.resolveCurrentID(
                download.currentRemoteID ?? download.historicalID,
                serverId: serverID,
                entityType: .song
            )
            let match: RemoteIdentityMatch?
            if catalogIDs.contains(resolved) {
                match = RemoteIdentityMatch(songID: resolved, confidence: 1, source: .serverResponse)
            } else {
                match = RemoteIdentityMatcher.match(download: download, candidates: catalog)
            }

            guard let match, let song = catalog.first(where: { $0.id == match.songID }) else {
                await identityService.setNeedsRelink(
                    true,
                    remoteID: download.historicalID,
                    serverId: serverID,
                    entityType: .song
                )
                continue
            }

            if download.historicalID != song.id {
                _ = await identityService.registerAlias(
                    oldID: download.historicalID,
                    newID: song.id,
                    serverId: serverID,
                    entityType: .song,
                    verificationSource: match.source,
                    confidence: match.confidence,
                    jellyfinID: NavidromeJellyfinIDCodec.jellyfinGUID(fromCanonicalID: song.id)
                )
            } else {
                _ = await identityService.observe(
                    remoteID: song.id,
                    serverId: serverID,
                    entityType: .song,
                    jellyfinID: NavidromeJellyfinIDCodec.jellyfinGUID(fromCanonicalID: song.id)
                )
            }
            await registerRelatedAliases(download: download, song: song, serverID: serverID, match: match)
            let stableID = await identityService.observe(
                remoteID: song.id,
                serverId: serverID,
                entityType: .song,
                jellyfinID: NavidromeJellyfinIDCodec.jellyfinGUID(fromCanonicalID: song.id)
            )
            await updateDownload(download, song: song, stableID: stableID, serverID: serverID)
        }
    }

    private func registerRelatedAliases(
        download: DownloadIdentitySnapshot,
        song: Song,
        serverID: UUID,
        match: RemoteIdentityMatch
    ) async {
        let pairs: [(String?, String?, RemoteMediaEntityType)] = [
            (download.albumID, song.albumId, .album),
            (download.artistID, song.artistId, .artist),
            (download.coverArtID, song.coverArt, .coverArt),
        ]
        for (oldID, newID, type) in pairs {
            guard let oldID, let newID, !oldID.isEmpty, !newID.isEmpty else { continue }
            if oldID == newID {
                _ = await identityService.observe(remoteID: newID, serverId: serverID, entityType: type)
            } else {
                _ = await identityService.registerAlias(
                    oldID: oldID,
                    newID: newID,
                    serverId: serverID,
                    entityType: type,
                    verificationSource: match.source,
                    confidence: match.confidence,
                    jellyfinID: NavidromeJellyfinIDCodec.jellyfinGUID(fromCanonicalID: newID)
                )
            }
        }
    }

    private func snapshots(serverID: UUID) async -> [DownloadIdentitySnapshot] {
        await MainActor.run {
            let context = ModelContext(modelContainer)
            let sid = serverID
            let rows = (try? context.fetch(FetchDescriptor<DownloadedTrack>(predicate: #Predicate {
                $0.serverId == sid
            }))) ?? []
            return rows.map {
                DownloadIdentitySnapshot(
                    recordID: $0.id,
                    historicalID: $0.songId,
                    currentRemoteID: $0.currentRemoteID,
                    albumID: $0.albumId,
                    artistID: $0.artistId,
                    coverArtID: $0.coverArtId,
                    title: $0.title,
                    artist: $0.artist,
                    album: $0.album,
                    discNumber: $0.discNumber,
                    trackNumber: $0.trackNumber,
                    durationSeconds: $0.durationSeconds,
                    mediaPath: $0.mediaPath,
                    musicBrainzID: $0.musicBrainzID,
                    isrc: $0.isrc
                )
            }
        }
    }

    private func updateDownload(
        _ download: DownloadIdentitySnapshot,
        song: Song,
        stableID: String,
        serverID: UUID
    ) async {
        await MainActor.run {
            let context = ModelContext(modelContainer)
            let recordID = download.recordID
            var descriptor = FetchDescriptor<DownloadedTrack>(predicate: #Predicate { $0.id == recordID })
            descriptor.fetchLimit = 1
            guard let row = try? context.fetch(descriptor).first else { return }
            row.localStableID = stableID
            row.currentRemoteID = song.id
            row.jellyfinID = NavidromeJellyfinIDCodec.jellyfinGUID(fromCanonicalID: song.id)
            var legacy = row.legacyRemoteIDs ?? []
            for value in [row.songId, download.currentRemoteID].compactMap({ $0 })
            where value != song.id && !legacy.contains(value) {
                legacy.append(value)
            }
            row.legacyRemoteIDs = legacy
            row.albumId = song.albumId ?? row.albumId
            row.artistId = song.artistId ?? row.artistId
            row.coverArtId = song.coverArt ?? row.coverArtId
            row.discNumber = song.discNumber ?? row.discNumber
            row.mediaPath = song.path ?? row.mediaPath
            row.musicBrainzID = song.musicBrainzId ?? row.musicBrainzID
            row.isrc = song.isrc?.first ?? row.isrc
            try? context.save()
        }
        await identityService.setNeedsRelink(
            false,
            remoteID: song.id,
            serverId: serverID,
            entityType: .song
        )
    }
}
