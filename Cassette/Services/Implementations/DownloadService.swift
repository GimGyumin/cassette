// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import CryptoKit
import SwiftData
import SwiftSonic
import OSLog
import Synchronization

private nonisolated struct JellyfinOriginalDownloadSource: Sendable {
    let url: URL
    let expectedSize: Int64?
    let container: String?
}

actor DownloadService: DownloadServiceProtocol {
    nonisolated private let originalArtworkLoader = Mutex<(@Sendable (String, UUID) async -> Bool)?>(nil)

    /// Wired once by AppContainer so explicit audio downloads and cover preparation share
    /// the same original producer. The weak cache capture avoids a service retain cycle.
    nonisolated func setOriginalArtworkLoader(_ loader: @escaping @Sendable (String, UUID) async -> Bool) {
        originalArtworkLoader.withLock { $0 = loader }
    }
    private let serverService: any ServerServiceProtocol
    private let modelContainer: ModelContainer
    private let mediaIdentityService: MediaIdentityService?
    private let jellyfinService: JellyfinService?
    private let usesUnifiedAudio: Bool
    private let downloadsDirectory: URL
    private let coverArtsDirectory: URL
    private var progressContinuation: AsyncStream<[DownloadProgress]>.Continuation?
    /// Keyed by "songId::serverId" to allow per-track cancellation.
    private struct Flight {
        let id: UUID
        let task: Task<Void, Error>
    }
    private var inFlightTasks: [String: Flight] = [:]
    /// Cover requests are shared by every track that references the same artwork ID. Album
    /// downloads run several audio transfers at once, so a disk-only existence check can race
    /// and issue the same artwork request multiple times before the first write finishes.
    private var inFlightCoverTasks: [String: Task<Void, Error>] = [:]
    private var albumBatchTasks: [String: Flight] = [:]
    private var playlistBatchTasks: [String: Flight] = [:]
    private var cancellationTask: Task<Void, Never>?
    private var downloadGeneration: UInt64 = 0
    private var recoveryInProgress = false
    private let journal: BackgroundDownloadJournal
    private let transferCoordinator: MediaTransferCoordinator
    private let cacheService: (any CacheServiceProtocol)?
    #if os(iOS)
    private let backgroundDownloads: CassetteBackgroundDownloads
    #endif
    private let toastService: ToastService
    /// Small cover fetches stay on a foreground session (background sessions don't support data tasks).
    private let coverSession: URLSession
    #if os(macOS)
    /// macOS keeps a long-lived foreground media session (no background-session relaunch path).
    private let mediaSession: URLSession
    #endif

    nonisolated let progressStream: AsyncStream<[DownloadProgress]>

    init(
        serverService: any ServerServiceProtocol,
        modelContainer: ModelContainer,
        toastService: ToastService,
        mediaIdentityService: MediaIdentityService? = nil,
        jellyfinService: JellyfinService? = nil,
        journal: BackgroundDownloadJournal = .shared,
        storageDirectory: URL? = nil,
        transferCoordinator: MediaTransferCoordinator = MediaTransferCoordinator(),
        cacheService: (any CacheServiceProtocol)? = nil
    ) {
        self.serverService = serverService
        self.modelContainer = modelContainer
        self.toastService = toastService
        self.mediaIdentityService = mediaIdentityService
        self.jellyfinService = jellyfinService
        self.journal = journal
        self.transferCoordinator = transferCoordinator
        self.cacheService = cacheService
        #if os(iOS)
        self.backgroundDownloads = journal === BackgroundDownloadJournal.shared ? .shared
            : CassetteBackgroundDownloads(identifier: "app.cassette.tests.\(UUID())", journal: journal)
        #endif

        let coverConfig = URLSessionConfiguration.default
        ArtworkNetworkPolicy.configure(coverConfig)
        coverConfig.timeoutIntervalForRequest = 60
        coverConfig.timeoutIntervalForResource = 120
        self.coverSession = URLSession(configuration: coverConfig)
        #if os(macOS)
        let mediaConfig = URLSessionConfiguration.default
        // Request idle timeout can stay modest; the full-file budget must not.
        mediaConfig.timeoutIntervalForRequest = 60
        mediaConfig.timeoutIntervalForResource = 600
        self.mediaSession = URLSession(configuration: mediaConfig)
        #else
        // Warm the shared background media session so suspended downloads keep running.
        _ = CassetteBackgroundDownloads.shared
        #endif

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let base = storageDirectory ?? docs.appendingPathComponent("app.cassette", isDirectory: true)
        self.usesUnifiedAudio = cacheService != nil
        self.downloadsDirectory = base.appendingPathComponent(cacheService != nil ? "audio" : "downloads", isDirectory: true)
        self.coverArtsDirectory = base.appendingPathComponent("coverarts", isDirectory: true)

        // AsyncStream.init closure is called synchronously — cont is guaranteed set before init returns.
        var cont: AsyncStream<[DownloadProgress]>.Continuation!
        progressStream = AsyncStream<[DownloadProgress]>(bufferingPolicy: .bufferingNewest(1)) { cont = $0 }
        progressContinuation = cont
    }

    private var storageRemovalTask: Task<Void, Never>?

    // MARK: - Lookup

    func downloadedURL(forSongId songId: String, serverId: UUID) async -> URL? {
        if let cache = cacheService as? CacheService { await cache.prepareUnifiedAudio() }
        return await downloadedURL(forSongId: songId, serverId: serverId, requiresOriginal: false)
    }

    func downloadedOriginalURL(forSongId songId: String, serverId: UUID) async -> URL? {
        await downloadedURL(forSongId: songId, serverId: serverId, requiresOriginal: true)
    }

    private func downloadedURL(forSongId songId: String, serverId: UUID, requiresOriginal: Bool) async -> URL? {
        if let cache = cacheService as? CacheService { await cache.prepareUnifiedAudio() }
        let candidates = await mediaIdentityService?.candidateRemoteIDsInBackground(
            for: songId, serverId: serverId, entityType: .song
        ) ?? [songId]
        guard !Task.isCancelled else { return nil }
        let candidateSet = Set(candidates)
        let entry: (filePath: String, fileSize: Int64)? = {
            let context = ModelContext(modelContainer)
            let sid = serverId
            var descriptor = FetchDescriptor<DownloadedTrack>(predicate: #Predicate {
                $0.serverId == sid && candidates.contains($0.songId)
            })
            descriptor.fetchLimit = 1
            var match = try? context.fetch(descriptor).first
            if match == nil {
                for candidate in candidates {
                    var current = FetchDescriptor<DownloadedTrack>(predicate: #Predicate {
                        $0.serverId == sid && $0.currentRemoteID == candidate
                    })
                    current.fetchLimit = 1
                    match = try? context.fetch(current).first
                    if match != nil { break }
                }
            }
            if match == nil {
                // Only legacy alias rows need an in-memory membership check.
                let aliases = FetchDescriptor<DownloadedTrack>(predicate: #Predicate {
                    $0.serverId == sid && $0.legacyRemoteIDs != nil
                })
                match = (try? context.fetch(aliases))?.first {
                    !candidateSet.isDisjoint(with: $0.legacyRemoteIDs ?? [])
                }
            }
            guard let track = match else { return nil }
            let legacyOriginal: Bool = track.isOriginalAudio == nil
                && ["audio/eac3", "audio/ec3", "audio/ac3", "audio/flac", "audio/x-flac", "audio/alac", "audio/wav", "audio/x-wav"].contains(track.mimeType.lowercased())
            guard !requiresOriginal || track.isOriginalAudio == true || legacyOriginal else { return nil }
            // Older downloads kept source surround metadata even after lossy transcoding.
            // Keep that file on disk, but allow a new original download to replace it.
            let mime = track.mimeType.lowercased()
            if (track.channelCount ?? 0) > 2,
               !["mp3", "opus", "ogg", "oga"].contains(track.suffix?.lowercased() ?? ""),
               ["audio/mpeg", "audio/mp3", "audio/opus", "audio/ogg"].contains(mime) {
                return nil
            }
            return (track.filePath, track.fileSize)
        }()
        guard let entry else { return nil }
        let url = downloadsDirectory.appendingPathComponent(entry.filePath)
        // A missing, empty, or size-mismatched file must fall through to cache/stream —
        // never hand a broken local file to the player. The file is NOT deleted here
        // (permanent downloads are user data); the record's size 0 means a legacy entry
        // whose size read failed at write time, where only non-emptiness can be checked.
        let diskSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        guard diskSize > 0, entry.fileSize == 0 || diskSize == entry.fileSize else {
            Logger.download.warning("Downloaded track record exists but file missing or invalid (disk \(diskSize) bytes, record \(entry.fileSize)): \(entry.filePath, privacy: .public)")
            return nil
        }
        do { try LocalAudioFileStore.validate(url, size: diskSize, mimeType: nil, songID: songId) }
        catch { return nil } // Permanent user data remains available for explicit replacement.
        return url
    }

    func isDownloaded(songId: String, serverId: UUID) async -> Bool {
        await downloadedURL(forSongId: songId, serverId: serverId) != nil
    }

    private nonisolated struct OfflineTrack: Sendable {
        let song: DisplayableSong
        let ids: [String]
        let albumID: String?
        let filePath: String
        let fileSize: Int64
        let compatible: Bool
    }

    /// Extract values once on this service's executor; no models escape or cross an await.
    private func offlineTracks(serverId sid: UUID, candidates: Set<String>? = nil) -> [OfflineTrack] {
        let context = ModelContext(modelContainer)
        let rows: [DownloadedTrack]
        if let candidates {
            let ids = Array(candidates)
            let direct = (try? context.fetch(FetchDescriptor<DownloadedTrack>(predicate: #Predicate {
                $0.serverId == sid && ids.contains($0.songId)
            }))) ?? []
            let aliases = (try? context.fetch(FetchDescriptor<DownloadedTrack>(predicate: #Predicate {
                $0.serverId == sid && ($0.currentRemoteID != nil || $0.legacyRemoteIDs != nil)
            }))) ?? []
            var seen = Set<UUID>()
            rows = (direct + aliases.filter {
                $0.currentRemoteID.map(candidates.contains) == true || !candidates.isDisjoint(with: $0.legacyRemoteIDs ?? [])
            })
                .filter { seen.insert($0.id).inserted }
        } else {
            rows = (try? context.fetch(FetchDescriptor<DownloadedTrack>(predicate: #Predicate { $0.serverId == sid }))) ?? []
        }
        return rows.map { track in
            let downmixedSurround = (track.channelCount ?? 0) > 2
                && !["mp3", "opus", "ogg", "oga"].contains(track.suffix?.lowercased() ?? "")
                && ["audio/mpeg", "audio/mp3", "audio/opus", "audio/ogg"].contains(track.mimeType.lowercased())
            return OfflineTrack(song: DisplayableSong(from: track),
                ids: [track.songId, track.currentRemoteID].compactMap { $0 } + (track.legacyRemoteIDs ?? []),
                albumID: track.albumId, filePath: track.filePath, fileSize: track.fileSize, compatible: !downmixedSurround)
        }
    }

    private func isPlayable(_ track: OfflineTrack) -> Bool {
        guard track.compatible, !Task.isCancelled else { return false }
        let url = downloadsDirectory.appendingPathComponent(track.filePath)
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values?.isRegularFile == true, let size = values?.fileSize, size > 0 else { return false }
        return track.fileSize == 0 || Int64(size) == track.fileSize
    }

    func downloadedSongIds(serverId: UUID) async -> Set<String> {
        if let cache = cacheService as? CacheService { await cache.prepareUnifiedAudio() }
        let generation = downloadGeneration
        let tracks = offlineTracks(serverId: serverId).filter(isPlayable)
        let ids = Set(tracks.flatMap(\.ids))
        let expanded = await mediaIdentityService?.candidateRemoteIDsInBackground(for: ids, serverId: serverId, entityType: .song) ?? ids
        guard !Task.isCancelled, generation == downloadGeneration else { return [] }
        await reconcileDownloadCounts(serverId: serverId, tracks: tracks, usableIDs: expanded, generation: generation)
        guard !Task.isCancelled, generation == downloadGeneration else { return [] }
        return expanded
    }

    private func reconcileDownloadCounts(serverId sid: UUID, tracks: [OfflineTrack], usableIDs: Set<String>, generation: UInt64) async {
        let albumIDs: Set<String> = {
            let context = ModelContext(modelContainer)
            let rows = (try? context.fetch(FetchDescriptor<DownloadedAlbum>(predicate: #Predicate { $0.serverId == sid }))) ?? []
            return Set(rows.map(\.albumId))
        }()
        let aliases = await mediaIdentityService?.candidateRemoteIDMapInBackground(for: albumIDs, serverId: sid, entityType: .album)
            ?? Dictionary(uniqueKeysWithValues: albumIDs.map { ($0, [$0]) })
        guard !Task.isCancelled, generation == downloadGeneration else { return }
        var albumCounts: [String: Int] = [:]
        for track in tracks { if let id = track.albumID { albumCounts[id, default: 0] += 1 } }
        let context = ModelContext(modelContainer)
        var changed = false
        for album in (try? context.fetch(FetchDescriptor<DownloadedAlbum>(predicate: #Predicate { $0.serverId == sid }))) ?? [] {
            let count = album.songIds.map { $0.filter(usableIDs.contains).count }
                ?? Set(aliases[album.albumId] ?? [album.albumId]).reduce(0) { $0 + (albumCounts[$1] ?? 0) }
            if count != album.tracksCount { album.tracksCount = count; changed = true }
        }
        for playlist in (try? context.fetch(FetchDescriptor<DownloadedPlaylist>(predicate: #Predicate { $0.serverId == sid }))) ?? [] {
            let count = playlist.songIds.filter(usableIDs.contains).count
            if count != playlist.tracksCount { playlist.tracksCount = count; changed = true }
        }
        if changed { try? context.save() }
    }

    nonisolated static func coverStorageName(for id: String, serverId: UUID) -> String {
        coverStorageName(for: id, serverId: serverId, sharesContent: true)
    }

    nonisolated static func legacyCoverStorageName(for id: String, serverId: UUID) -> String {
        coverStorageName(for: id, serverId: serverId, sharesContent: false)
    }

    private nonisolated static func coverStorageName(for id: String, serverId: UUID, sharesContent: Bool) -> String {
        let parts = id.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
        let base = String(parts[0])
        let hash = SHA256.hash(data: Data((sharesContent ? ArtworkIdentity.key(base) : base).utf8)).map { String(format: "%02x", $0) }.joined()
        // Only known suffixes carry semantics; arbitrary remote IDs cannot become paths.
        let suffix = parts.count == 2 && ["thumb", "hero", "original-v1"].contains(String(parts[1])) ? "@" + parts[1] : ""
        let opaqueHash = suffix.isEmpty ? SHA256.hash(data: Data((sharesContent ? ArtworkIdentity.key(id) : id).utf8)).map { String(format: "%02x", $0) }.joined() : hash
        return serverId.uuidString + "--" + opaqueHash + suffix
    }

    func localCoverArtURL(forId coverArtId: String) async -> URL? {
        guard let sid = await MainActor.run(body: { serverService.state.activeServer?.id }) else { return nil }
        return await localCoverArtURL(forId: coverArtId, serverId: sid)
    }

    func localCoverArtURL(forId coverArtId: String, serverId: UUID) async -> URL? {
        let parts = coverArtId.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
        let baseID = String(parts[0])
        let suffix = parts.count == 2 ? "@" + parts[1] : ""
        let suffixes = suffix.isEmpty ? ["@original-v1", ""] : [suffix]
        for variant in suffixes {
            let url = coverArtsDirectory.appendingPathComponent(Self.coverStorageName(for: baseID + variant, serverId: serverId))
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        let candidates = await mediaIdentityService?.candidateRemoteIDsInBackground(
            for: baseID, serverId: serverId, entityType: .coverArt) ?? [baseID]
        guard !Task.isCancelled else { return nil }
        for candidate in candidates {
            for variant in suffixes {
                let url = coverArtsDirectory.appendingPathComponent(Self.coverStorageName(for: candidate + variant, serverId: serverId))
                if FileManager.default.fileExists(atPath: url.path) { return url }
                let previous = coverArtsDirectory.appendingPathComponent(Self.legacyCoverStorageName(for: candidate + variant, serverId: serverId))
                if previous != url, FileManager.default.fileExists(atPath: previous.path) {
                    do { try FileManager.default.moveItem(at: previous, to: url); return url } catch { return previous }
                }
                // Legacy global files have no reliable owner unless offline metadata proves
                // exactly one account references this ID. Keep ambiguous bytes, but don't display them.
                if !candidate.contains("/"), candidate != ".." {
                    let old = coverArtsDirectory.appendingPathComponent(candidate + variant)
                    if FileManager.default.fileExists(atPath: old.path), legacyCoverOwner(candidates) == serverId {
                        do { try FileManager.default.copyItem(at: old, to: url); return url } catch { }
                    }
                }
            }
        }
        return nil
    }

    private func legacyCoverOwner(_ candidates: [String]) -> UUID? {
        let context = ModelContext(modelContainer)
        let albums = (try? context.fetch(FetchDescriptor<DownloadedAlbum>())) ?? []
        let playlists = (try? context.fetch(FetchDescriptor<DownloadedPlaylist>())) ?? []
        let tracks = (try? context.fetch(FetchDescriptor<DownloadedTrack>())) ?? []
        var owners = Set<UUID>()
        for row in albums where row.coverArtId.map(candidates.contains) == true { owners.insert(row.serverId) }
        for row in playlists where row.coverArtId.map(candidates.contains) == true { owners.insert(row.serverId) }
        for row in tracks where row.coverArtId.map(candidates.contains) == true { owners.insert(row.serverId) }
        return owners.count == 1 ? owners.first : nil
    }

    func persistCover(_ data: Data, forId coverArtId: String) async {
        guard let sid = await MainActor.run(body: { serverService.state.isSigningOut ? nil : serverService.state.activeServer?.id }) else { return }
        await persistCover(data, forId: coverArtId, serverId: sid)
    }

    func persistCover(_ data: Data, forId coverArtId: String, serverId: UUID) async {
        guard let identity = try? await MainActor.run(body: { try serverService.state.requestIdentity(for: serverId) }) else { return }
        let name = Self.coverStorageName(for: coverArtId, serverId: serverId)
        guard await MainActor.run(body: { serverService.state.requestIsCurrent(identity) }), !Task.isCancelled else { return }
        do {
            try FileManager.default.createDirectory(at: coverArtsDirectory, withIntermediateDirectories: true)
            try ArtworkContentStore.write(data, to: coverArtsDirectory.appendingPathComponent(name))
        } catch { Logger.download.debug("Failed to persist scoped cover: \(error)") }
    }

    func removeCover(forId coverArtId: String) async {
        guard let sid = await MainActor.run(body: { serverService.state.activeServer?.id }) else { return }
        await removeCover(forId: coverArtId, serverId: sid)
    }

    func removeCover(forId coverArtId: String, serverId: UUID) async {
        let url = coverArtsDirectory.appendingPathComponent(Self.coverStorageName(for: coverArtId, serverId: serverId))
        if FileManager.default.fileExists(atPath: url.path) { try? FileManager.default.removeItem(at: url) }
    }

    @discardableResult
    func garbageCollectOrphanedCovers(referencedIds: Set<String>) async -> Int {
        let active = await MainActor.run { serverService.state.activeServer?.id }
        var retained = referencedIds
        if let active, let mediaIdentityService {
            retained = await mediaIdentityService.candidateRemoteIDsInBackground(
                for: referencedIds, serverId: active, entityType: .coverArt)
        }
        let accountClosed = await MainActor.run { serverService.state.isSigningOut || serverService.state.activeServer == nil }
        let clearAll = referencedIds.isEmpty && accountClosed
        let names = active.map { sid in Set(retained.flatMap { id in
            [Self.coverStorageName(for: id, serverId: sid),
             Self.coverStorageName(for: OriginalArtwork.storageID(id), serverId: sid)]
        }) } ?? []
        let entries = (try? FileManager.default.contentsOfDirectory(at: coverArtsDirectory, includingPropertiesForKeys: nil)) ?? []
        var count = 0
        for url in entries {
            let name = url.lastPathComponent
            // Ephemeral derivatives are independently evicted. A normal account cleanup
            // cannot remove another account's covers or ambiguously-owned legacy files.
            if !clearAll {
                guard let active, name.hasPrefix(active.uuidString + "--") else { continue }
                // Bulk/on-demand originals are referenced by the library, not just offline
                // audio/pins. A partial startup reference set cannot prove them orphaned.
                if name.hasSuffix("@original-v1") || name.hasSuffix("@thumb") || name.hasSuffix("@hero") { continue }
                if names.contains(name) { continue }
            }
            do { try FileManager.default.removeItem(at: url); count += 1 } catch { }
        }
        return count
    }

    func localAlbumData(albumId: String, serverId: UUID) async -> LocalAlbumData? {
        if let cache = cacheService as? CacheService { await cache.prepareUnifiedAudio() }
        let generation = downloadGeneration
        let albumIDs = Set(await mediaIdentityService?.candidateRemoteIDsInBackground(
            for: albumId, serverId: serverId, entityType: .album) ?? [albumId])
        let metadata: (String, String?, String?, [String]?)? = {
            let context = ModelContext(modelContainer)
            let sid = serverId
            let ids = Array(albumIDs)
            let row = try? context.fetch(FetchDescriptor<DownloadedAlbum>(predicate: #Predicate {
                $0.serverId == sid && ids.contains($0.albumId)
            })).first
            return row.map { ($0.name, $0.artist, $0.coverArtId, $0.songIds) }
        }()
        let tracks = offlineTracks(serverId: serverId).filter(isPlayable)
        let songs: [DisplayableSong]
        if let orderedIDs = metadata?.3 {
            var byID: [String: DisplayableSong] = [:]
            for track in tracks { for id in track.ids where byID[id] == nil { byID[id] = track.song } }
            songs = orderedIDs.compactMap { byID[$0] }
        } else {
            songs = tracks.filter { $0.albumID.map(albumIDs.contains) == true }.map(\.song)
                .sorted(by: AlbumDetailViewModel.albumTrackOrder)
        }
        guard let first = songs.first, !Task.isCancelled, generation == downloadGeneration else { return nil }
        return LocalAlbumData(albumId: albumId, albumName: metadata?.0 ?? first.albumName ?? albumId,
            artistName: metadata?.1 ?? first.artist, coverArtId: metadata?.2 ?? first.coverArtId, songs: songs)
    }

    func localPlaylistData(playlistId: String, serverId: UUID) async -> LocalPlaylistData? {
        if let cache = cacheService as? CacheService { await cache.prepareUnifiedAudio() }
        let generation = downloadGeneration
        let playlistIDs = await mediaIdentityService?.candidateRemoteIDsInBackground(
            for: playlistId, serverId: serverId, entityType: .playlist) ?? [playlistId]
        let metadata: (id: String, name: String, cover: String?, ids: [String])? = {
            let context = ModelContext(modelContainer)
            let sid = serverId
            let row = try? context.fetch(FetchDescriptor<DownloadedPlaylist>(predicate: #Predicate {
                $0.serverId == sid && playlistIDs.contains($0.playlistId)
            })).first
            return row.map { ($0.playlistId, $0.name, $0.coverArtId, $0.songIds) }
        }()
        guard let metadata, !Task.isCancelled else { return nil }
        let requested = Set(metadata.ids)
        let aliases = await mediaIdentityService?.candidateRemoteIDMapInBackground(
            for: requested, serverId: serverId, entityType: .song)
            ?? Dictionary(uniqueKeysWithValues: requested.map { ($0, [$0]) })
        let candidates = Set(aliases.values.flatMap { $0 })
        var byID: [String: DisplayableSong] = [:]
        for track in offlineTracks(serverId: serverId, candidates: candidates) where isPlayable(track) {
            for id in track.ids where byID[id] == nil { byID[id] = track.song }
        }
        // Linear assembly preserves playlist order and repeated occurrences.
        let songs = metadata.ids.compactMap { id in
            (aliases[id] ?? [id]).lazy.compactMap { byID[$0] }.first
        }
        guard !Task.isCancelled, generation == downloadGeneration else { return nil }
        return LocalPlaylistData(playlistId: metadata.id, name: metadata.name, coverArtId: metadata.cover, songs: songs)
    }

    func backfillPlaylistSongIds(playlistId: String, serverId: UUID, orderedSongIds: [String]) async {
        await MainActor.run {
            let context = ModelContext(modelContainer)
            let pid = playlistId
            let sid = serverId
            var playlistDescriptor = FetchDescriptor<DownloadedPlaylist>(
                predicate: #Predicate { $0.playlistId == pid && $0.serverId == sid }
            )
            playlistDescriptor.fetchLimit = 1
            // Only repair records that are actually missing their order. DownloadedTrack carries
            // no playlist link, so membership cannot be recovered from disk alone — the order must
            // come from the authoritative API list, intersected with what is actually downloaded.
            guard let record = try? context.fetch(playlistDescriptor).first,
                  record.songIds.isEmpty else { return }
            let downloaded = Set(
                ((try? context.fetch(FetchDescriptor<DownloadedTrack>(
                    predicate: #Predicate { $0.serverId == sid }
                ))) ?? [])
                    .map(\.songId)
            )
            let repaired = orderedSongIds.filter { downloaded.contains($0) }
            guard !repaired.isEmpty else { return }
            record.songIds = repaired
            do {
                try context.save()
                Logger.download.info("Back-filled \(repaired.count, privacy: .public) songId(s) for playlist '\(playlistId, privacy: .public)'")
            } catch {
                Logger.download.debug("DownloadService: songIds back-fill save failed — \(error)")
            }
        }
    }

    // MARK: - Single track download

    func download(song: Song, serverId: UUID) async throws {
        try await download(song: song, serverId: serverId, formatOverride: nil)
    }

    func downloadOriginal(song: Song, serverId: UUID) async throws {
        try await download(song: song, serverId: serverId, formatOverride: .flacOriginal)
    }

    private func download(song: Song, serverId: UUID, formatOverride: CacheFormat?) async throws {
        let generation = downloadGeneration
        try checkDownloadGeneration(generation)
        try await downloadAudio(song: song, serverId: serverId, albumCoverArtID: nil, generation: generation, formatOverride: formatOverride)
        try checkDownloadGeneration(generation)
        let songCoverArtID = song.coverArt?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedCoverArtID = songCoverArtID.flatMap { $0.isEmpty ? nil : $0 } ?? song.albumId ?? song.id
        do {
            try await _downloadCoverArt(id: resolvedCoverArtID, serverId: serverId)
        } catch {
            Logger.download.error("Cover art download failed for '\(song.id, privacy: .public)': \(error, privacy: .public)")
        }
        try checkDownloadGeneration(generation)
    }

    /// Downloads and records only the audio payload. Album downloads call this path so artwork
    /// can be planned once for the whole album: the shared album cover is fetched once and only
    /// tracks with a different cover-art ID add another request.
    private func downloadAudio(song: Song, serverId: UUID, albumCoverArtID: String?, generation: UInt64, formatOverride: CacheFormat? = nil) async throws {
        try checkDownloadGeneration(generation)
        let alreadyDownloaded = formatOverride == .flacOriginal
            ? await downloadedOriginalURL(forSongId: song.id, serverId: serverId) != nil
            : await isDownloaded(songId: song.id, serverId: serverId)
        guard !alreadyDownloaded else {
            Logger.download.debug("Song '\(song.id, privacy: .public)' already downloaded — skipping.")
            return
        }
        try checkDownloadGeneration(generation)

        let key = taskKey(songId: song.id, serverId: serverId)
        // Join an in-flight download instead of returning success while the file
        // is still missing — that made the first tap look like a no-op/failure.
        if let existing = inFlightTasks[key], !existing.task.isCancelled {
            try await existing.task.value
            try checkDownloadGeneration(generation)
            // An in-flight AAC download cannot satisfy an explicit original request.
            if formatOverride == .flacOriginal,
               await downloadedOriginalURL(forSongId: song.id, serverId: serverId) == nil {
                try await downloadAudio(song: song, serverId: serverId, albumCoverArtID: albumCoverArtID,
                                        generation: generation, formatOverride: formatOverride)
            }
            return
        }

        let id = UUID()
        let task = Task<Void, Error> {
            defer { if self.inFlightTasks[key]?.id == id { self.inFlightTasks[key] = nil } }
            try self.checkDownloadGeneration(generation)
            try await self._downloadSong(
                song,
                serverId: serverId,
                albumCoverArtID: albumCoverArtID,
                formatOverride: formatOverride
            )
        }
        inFlightTasks[key] = Flight(id: id, task: task)
        try await awaitOwnedDownload(task)
        try checkDownloadGeneration(generation)
    }

    private func _downloadSong(
        _ song: Song,
        serverId: UUID,
        albumCoverArtID: String?,
        formatOverride: CacheFormat?
    ) async throws {
        let identity = try await MainActor.run { try serverService.state.requestIdentity(for: serverId) }
        let creds = try await serverService.activeCredentials()
        let client = try await serverService.makeSwiftSonicClient()
        try Task.checkCancellation()
        guard await MainActor.run(body: { serverService.state.requestIsCurrent(identity) }) else {
            throw CancellationError()
        }
        let formatRaw = UserDefaults.standard.string(forKey: "cassette.streaming.download")
        // Download quality is an explicit encoding instruction, including for spatial/ambiguous
        // catalog metadata. Automatic/original already request raw bytes in the switch below.
        let requestedFormat = formatOverride ?? StreamingSettings.effectiveFormat(
            CacheFormat(rawValue: formatRaw ?? "") ?? .matchStream,
            losslessEnabled: UserDefaults.standard.object(forKey: StreamingSettings.losslessAudioKey) as? Bool ?? true
        )
        var mediaURL: URL?
        var expectedOriginalSize: Int64?
        var originalContainer: String?
        switch requestedFormat {
        case .flacOriginal:
            if let jellyfinService,
               let jellyfinID = NavidromeJellyfinIDCodec.jellyfinGUID(fromCanonicalID: song.id) {
                let source = try? await jellyfinService.perform(feature: .originalFile) { client -> JellyfinOriginalDownloadSource? in
                    let playbackInfo = try await client.playbackInfo(itemID: jellyfinID)
                    guard let url = client.downloadURL(itemID: jellyfinID)
                        ?? client.originalFileURL(itemID: jellyfinID) else { return nil }
                    return JellyfinOriginalDownloadSource(
                        url: url,
                        expectedSize: playbackInfo.mediaSources.first?.containerSize,
                        container: playbackInfo.mediaSources.first?.container
                    )
                }
                mediaURL = source?.url
                expectedOriginalSize = source?.expectedSize
                originalContainer = source?.container
            } else {
                mediaURL = nil
            }
            if mediaURL == nil {
                mediaURL = client.streamURL(id: song.id, format: "raw")
            }
        case .matchStream:
            mediaURL = client.streamURL(id: song.id, format: "raw")
        default:
            mediaURL = client.streamURL(
                id: song.id,
                maxBitRate: requestedFormat.subsonicMaxBitRate,
                format: requestedFormat.subsonicFormat
            )
        }
        guard let mediaURL else {
            throw CassetteError.mediaNotFound(songId: song.id)
        }

        var request = URLRequest(url: mediaURL)
        for (k, v) in creds.customHeaders { request.setValue(v, forHTTPHeaderField: k) }

        let intent = BackgroundDownloadJournal.Record(song: song, serverID: serverId,
            format: requestedFormat, albumCoverArtID: albumCoverArtID,
            expectedOriginalSize: expectedOriginalSize, originalContainer: originalContainer)
        guard await MainActor.run(body: { serverService.state.requestIsCurrent(identity) }), !Task.isCancelled else {
            throw CancellationError()
        }
        let key = MediaTransferKey(accountID: serverId, revision: identity.revision, songID: song.id, request: request)
        let transferRequest = request
        try await transferCoordinator.permanent(key) { [weak self] cached in
            guard let self else { throw CancellationError() }
            try await self.performCoordinatedDownload(intent, request: transferRequest, cached: cached, identity: identity)
        }
    }

    private func performCoordinatedDownload(_ intent: BackgroundDownloadJournal.Record, request: URLRequest,
                                            cached: CachedMediaTransfer?, identity: ServerRequestIdentity) async throws {
        guard await MainActor.run(body: { serverService.state.requestIsCurrent(identity) }), !Task.isCancelled else {
            throw CancellationError()
        }
        let song = intent.song
        let serverId = intent.serverID
        let key = MediaTransferKey(accountID: serverId, revision: identity.revision, songID: song.id, request: request)
        let persisted = cached == nil ? await cacheService?.completedTransfer(for: key) : nil
        let reusable = cached ?? persisted
        if let reusable, let copy = await reusable.copyForInstallation() {
            defer { try? FileManager.default.removeItem(at: copy) }
            try Task.checkCancellation()
            #if os(iOS)
            try journal.insert(intent)
            let staged = try journal.stage(id: intent.id, file: copy, response: reusable.response)
            #else
            let staged = copy
            #endif
            try await installDownloadedAudio(intent, tempURL: staged, response: reusable.response, identity: identity, transferKey: key)
            journal.remove(intent.id)
            return
        }
        emit(progress: DownloadProgress(songId: song.id, serverId: serverId, progress: 0, totalBytes: nil, receivedBytes: 0))

        let progressSink = progressContinuation
        let progressSongId = song.id
        let progressServerId = serverId
        let (tempURL, response): (URL, URLResponse)
        #if os(iOS)
        try journal.insert(intent)
        (tempURL, response) = try await backgroundDownloads.download(
            request: request,
            clientKey: taskKey(songId: song.id, serverId: serverId),
            recoveryID: intent.id,
            onProgress: { received, total in
                let fraction: Double
                if let total, total > 0 {
                    fraction = min(1.0, Double(received) / Double(total))
                } else {
                    fraction = 0
                }
                progressSink?.yield([
                    DownloadProgress(
                        songId: progressSongId,
                        serverId: progressServerId,
                        progress: fraction,
                        totalBytes: total,
                        receivedBytes: received
                    )
                ])
            }
        )
        #else
        (tempURL, response) = try await mediaSession.download(for: request)
        #endif
        #if os(macOS)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        #endif

        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw CassetteError.downloadFailed(songId: song.id,
                underlying: HTTPTransferFailure(response: response, stage: "audio download response"))
        }

        try await installDownloadedAudio(intent, tempURL: tempURL, response: response, identity: identity, transferKey: key)
        journal.remove(intent.id)
    }

    /// Normal completion and relaunch recovery share validation, encoding and metadata commit.
    func installDownloadedAudio(_ intent: BackgroundDownloadJournal.Record, tempURL: URL, response: URLResponse,
                                identity: ServerRequestIdentity? = nil, transferKey: MediaTransferKey? = nil) async throws {
        let song = intent.song
        let serverId = intent.serverID
        let requestedFormat = intent.format
        let albumCoverArtID = intent.albumCoverArtID
        let expectedOriginalSize = intent.expectedOriginalSize
        let originalContainer = intent.originalContainer
        let accountIsActive = await MainActor.run {
            serverService.state.activeServer?.id == serverId && !serverService.state.isSigningOut
                && (identity.map { serverService.state.requestIsCurrent($0) } ?? true)
        }
        guard accountIsActive else { throw CancellationError() }

        // Never save a poisoned payload as a permanent download (Subsonic error-as-200
        // envelope, empty or truncated body) — unlike the cache it is never evicted,
        // so a broken file would play as silence forever.
        do {
            try AudioResponseValidator.validate(fileAt: tempURL, response: response, songId: song.id, logger: Logger.download)
        } catch {
            throw CassetteError.downloadFailed(songId: song.id, underlying: error)
        }

        if let expectedOriginalSize, expectedOriginalSize > 0 {
            let receivedSize = (try? FileManager.default.attributesOfItem(atPath: tempURL.path)[.size] as? Int64) ?? 0
            guard receivedSize == expectedOriginalSize else {
                struct OriginalSizeMismatch: Error & Sendable {
                    let expected: Int64
                    let received: Int64
                }
                throw CassetteError.downloadFailed(
                    songId: song.id,
                    underlying: OriginalSizeMismatch(expected: expectedOriginalSize, received: receivedSize)
                )
            }
        }

        var payloadURL = tempURL
        var mimeType = response.mimeType ?? "audio/mpeg"
        var locallyEncodedAAC = false
        if requestedFormat == .aac128 || requestedFormat == .aac256 {
            do {
                let encoded = try await AACDownloadEncoder.prepare(fileAt: tempURL,
                    bitRate: (requestedFormat.subsonicMaxBitRate ?? 256) * 1_000)
                payloadURL = encoded.url
                locallyEncodedAAC = encoded.wasEncoded
                if encoded.wasEncoded { mimeType = "audio/mp4" }
            } catch {
                throw CassetteError.downloadFailed(songId: song.id, underlying: error)
            }
        }
        defer { if payloadURL != tempURL { try? FileManager.default.removeItem(at: payloadURL) } }
        try Task.checkCancellation()
        let ext = requestedFormat.downloadFileExtension(
            mimeType: locallyEncodedAAC ? mimeType : response.mimeType,
            originalSuffix: song.suffix ?? originalContainer
        )
        let relativePath = "\(serverId.uuidString)/\(UUID().uuidString).\(ext)"
        let fileURL = downloadsDirectory.appendingPathComponent(relativePath)

        let unified = usesUnifiedAudio
        ManagedAudioStore.shared.acquire(fileURL)
        defer { ManagedAudioStore.shared.release(fileURL) }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
        // Keep staged bytes until SwiftData commits, including across process termination.
        try LocalAudioFileStore.install(payloadURL, at: fileURL, sharesImmutableSource: true)
        var committed = false
        defer { if !committed { try? FileManager.default.removeItem(at: fileURL) } }

        // Faststart-remux non-faststart m4a for AudioStreaming offline playback.
        // Skip Atmos / multichannel — remux can strip spatial bitstreams; those use AVPlayer.
        let skipRemux: Bool = {
            let probe = DisplayableSong(from: song)
            return requestedFormat.subsonicMaxBitRate == nil && AudioQualityClassifier.requiresSystemPlayer(probe)
        }()
        var wasRemuxed = false
        if !skipRemux, case .remuxed = await AudioFaststartRemuxer().remuxToFaststartIfNeeded(at: fileURL) {
            wasRemuxed = true
            Logger.download.info("Faststart-remuxed m4a download '\(song.id, privacy: .public)'")
        } else if skipRemux {
            Logger.download.info("[SPATIAL] Skipping faststart remux for Dolby/multichannel '\(song.id, privacy: .public)'")
        }

        // Capture only Sendable values for the MainActor closure.
        let songId = song.id
        let savedMimeType = mimeType
        let albumId = song.albumId
        let artistId = song.artistId
        let title = song.title
        let artist = song.artist
        let album = song.album
        let genre = song.genres?.first?.name ?? song.genre
        let track = song.track
        let disc = song.discNumber
        let duration = song.duration
        let mediaPath = song.path
        let musicBrainzID = song.musicBrainzId
        let isrc = song.isrc?.first
        let coverArtId = song.coverArt ?? albumCoverArtID
        let isTranscoded = requestedFormat.subsonicMaxBitRate != nil
        let suffix = ext
        let bitRate = isTranscoded ? requestedFormat.subsonicMaxBitRate : song.bitRate
        let bitDepth = isTranscoded ? nil : song.bitDepth
        let samplingRate = isTranscoded ? nil : song.samplingRate
        let channelCount = isTranscoded ? nil : song.channelCount
        let comment = song.comment
        let explicitStatus = song.explicitStatus
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? 0
        let rgTrackGain    = song.replayGain?.trackGain
        let rgTrackPeak    = song.replayGain?.trackPeak
        let rgAlbumGain    = song.replayGain?.albumGain
        let rgAlbumPeak    = song.replayGain?.albumPeak
        let rgBaseGain     = song.replayGain?.baseGain
        let rgFallbackGain = song.replayGain?.fallbackGain

        let savedTransferIdentity = !locallyEncodedAAC && !wasRemuxed ? try transferKey.map { try JSONEncoder().encode($0) } : nil

        // Commit audio before fetching optional artwork so slow covers cannot hide a finished track.
        let supersededPaths = try await MainActor.run {
            guard !Task.isCancelled, serverService.state.activeServer?.id == serverId,
                  !serverService.state.isSigningOut,
                  identity.map({ serverService.state.requestIsCurrent($0) }) ?? true else { throw CancellationError() }
            return try ManagedAudioStore.shared.withLock {
                let context = ModelContext(modelContainer)
                let stableID = mediaIdentityService?.observe(
                    remoteID: songId,
                    serverId: serverId,
                    entityType: .song
                )
                let record = DownloadedTrack(
                    localStableID: stableID,
                    songId: songId,
                    serverId: serverId,
                    albumId: albumId,
                    filePath: relativePath,
                    fileSize: fileSize,
                    mimeType: savedMimeType,
                    isOriginalAudio: !isTranscoded,
                    title: title,
                    artist: artist,
                    artistId: artistId,
                    album: album,
                    trackNumber: track,
                    discNumber: disc,
                    durationSeconds: duration,
                    mediaPath: mediaPath,
                    musicBrainzID: musicBrainzID,
                    isrc: isrc,
                    coverArtId: coverArtId,
                    suffix: suffix,
                    genre: genre,
                    bitRate: bitRate,
                    bitDepth: bitDepth,
                    samplingRate: samplingRate,
                    channelCount: channelCount,
                    comment: comment,
                    explicitStatus: explicitStatus,
                    replayGainTrackGain: rgTrackGain,
                    replayGainTrackPeak: rgTrackPeak,
                    replayGainAlbumGain: rgAlbumGain,
                    replayGainAlbumPeak: rgAlbumPeak,
                    replayGainBaseGain: rgBaseGain,
                    replayGainFallbackGain: rgFallbackGain
                )
                let previous = try context.fetch(FetchDescriptor<DownloadedTrack>(predicate: #Predicate {
                    $0.songId == songId && $0.serverId == serverId
                }))
                var supersededPaths = previous.map(\.filePath)
                if unified {
                    let existing = try context.fetch(FetchDescriptor<CachedTrack>(predicate: #Predicate {
                        $0.songId == songId && $0.serverId == serverId
                    })).first
                    let asset = existing ?? CachedTrack(songId: songId, serverId: serverId, filePath: relativePath,
                                                        fileSize: fileSize, mimeType: savedMimeType)
                    if let existing { supersededPaths.append(existing.filePath) } else { context.insert(asset) }
                    asset.filePath = relativePath
                    asset.fileSize = fileSize
                    asset.mimeType = savedMimeType
                    asset.isPinned = true
                    asset.transferIdentity = savedTransferIdentity
                }
                for old in previous { context.delete(old) }
                context.insert(record)
                do {
                    try context.save()
                } catch {
                    context.rollback()
                    try? FileManager.default.removeItem(at: fileURL)
                    Logger.download.error("DownloadService: track record save failed for '\(songId, privacy: .public)' — \(error)")
                    throw error
                }
                return supersededPaths
            }
        }
        committed = true
        for path in supersededPaths where path != relativePath {
            removeUnreferencedAudio(path)
        }

        emit(progress: DownloadProgress(songId: song.id, serverId: serverId, progress: 1.0, totalBytes: fileSize, receivedBytes: fileSize))
        Logger.download.info("Downloaded '\(song.id, privacy: .public)' (\(fileSize) bytes)")
    }

    // MARK: - Album download

    func recoverBackgroundDownloads() async {
        guard !recoveryInProgress else { return }
        recoveryInProgress = true
        defer { recoveryInProgress = false }
        let generation = downloadGeneration
        guard cancellationTask == nil else { return }
        let activeID = await MainActor.run { serverService.state.activeServer?.id }
        for record in journal.completed() where record.serverID == activeID {
            guard downloadGenerationIsCurrent(generation) else { return }
            let key = taskKey(songId: record.song.id, serverId: record.serverID)
            guard inFlightTasks[key] == nil else { continue }
            do {
                if !(await isDownloaded(songId: record.song.id, serverId: record.serverID)) {
                    try checkDownloadGeneration(generation)
                    guard inFlightTasks[key] == nil else { continue }
                    let task = Task { try await self.installDownloadedAudio(record,
                        tempURL: self.journal.payloadURL(record.id), response: record.response) }
                    let id = UUID()
                    inFlightTasks[key] = Flight(id: id, task: task)
                    defer { if inFlightTasks[key]?.id == id { inFlightTasks[key] = nil } }
                    try await awaitOwnedDownload(task)
                }
                journal.remove(record.id)
            } catch {
                // A disk/database failure remains recoverable at the next foreground/launch.
                Logger.download.error("Restored download commit failed: \(error, privacy: .private)")
            }
        }
    }

    func download(album: AlbumID3, serverId: UUID) async throws {
        let generation = downloadGeneration
        try checkDownloadGeneration(generation)
        try await runBatch(key: taskKey(songId: album.id, serverId: serverId), playlist: false) {
            try await self.performAlbumDownload(album, serverId: serverId, generation: generation)
        }
    }

    private func performAlbumDownload(_ album: AlbumID3, serverId: UUID, generation: UInt64) async throws {
        guard let songs = album.song else { return }
        let total = songs.count
        let albumCoverArtID = album.coverArt?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedAlbumCoverArtID = albumCoverArtID?.isEmpty == false ? albumCoverArtID : nil
        let succeeded = try await DownloadBatchRunner.run(songs, shouldContinue: {
            await self.downloadGenerationIsCurrent(generation)
        }) { song in
            do {
                try await self.downloadAudio(song: song, serverId: serverId,
                    albumCoverArtID: normalizedAlbumCoverArtID, generation: generation)
                return true
            } catch { return false }
        }
        try checkDownloadGeneration(generation)

        var localCoverPath: String? = nil
        let coverArtIDs = Self.albumCoverArtIDs(
            albumCoverArtID: normalizedAlbumCoverArtID,
            songCoverArtIDs: songs.map(\.coverArt)
        )
        for coverArtId in coverArtIDs {
            try checkDownloadGeneration(generation)
            do {
                try await _downloadCoverArt(id: coverArtId, serverId: serverId)
                if coverArtId == normalizedAlbumCoverArtID { localCoverPath = Self.coverStorageName(for: OriginalArtwork.storageID(coverArtId), serverId: serverId) }
            } catch {
                Logger.download.error("Cover art download failed for album '\(album.id, privacy: .public)' (coverArtId: \(coverArtId, privacy: .public)): \(error, privacy: .public)")
            }
        }

        try checkDownloadGeneration(generation)
        let albumId = album.id
        let albumName = album.name
        let albumArtist = album.artist
        let coverArt = album.coverArt
        let tracksSucceeded = succeeded
        let totalTracks = total
        let coverPath = localCoverPath

        await MainActor.run {
            guard !Task.isCancelled, serverService.state.activeServer?.id == serverId,
                  !serverService.state.isSigningOut else { return }
            let context = ModelContext(modelContainer)
            let sid = serverId
            let existing = (try? context.fetch(FetchDescriptor<DownloadedAlbum>(predicate: #Predicate {
                $0.albumId == albumId && $0.serverId == sid
            })))?.first

            if let existing {
                existing.tracksCount = tracksSucceeded
                existing.songIds = songs.map(\.id)
                existing.totalTracksCount = totalTracks
                existing.downloadedAt = Date()
                if let coverPath { existing.localCoverArtPath = coverPath }
            } else {
                let record = DownloadedAlbum(
                    albumId: albumId,
                    serverId: serverId,
                    name: albumName,
                    artist: albumArtist,
                    tracksCount: tracksSucceeded,
                    totalTracksCount: totalTracks,
                    coverArtId: coverArt,
                    localCoverArtPath: coverPath,
                    songIds: songs.map(\.id)
                )
                context.insert(record)
            }
            do {
                try context.save()
            } catch {
                Logger.download.debug("DownloadService: album record save failed — \(error)")
            }
        }
        try checkDownloadGeneration(generation)
        Logger.download.info("Album '\(album.id, privacy: .public)': \(succeeded)/\(total) tracks downloaded.")
        if succeeded == total, total > 0 {
            await toastService.showSuccess("\(album.name) downloaded")
        } else if succeeded == 0, total > 0 {
            await toastService.showError(UserFacingError.downloadFailed.displayMessage)
        }
    }

    // MARK: - Playlist download

    func download(playlist: PlaylistWithSongs, serverId: UUID) async throws {
        let generation = downloadGeneration
        try checkDownloadGeneration(generation)
        try await runBatch(key: taskKey(songId: playlist.id, serverId: serverId), playlist: true) {
            try await self.performPlaylistDownload(playlist, serverId: serverId, generation: generation)
        }
    }

    private func performPlaylistDownload(_ playlist: PlaylistWithSongs, serverId: UUID, generation: UInt64) async throws {
        let songs = playlist.entry ?? []
        let total = songs.count
        _ = try await downloadSongs(songs, serverId: serverId, generation: generation)
        try checkDownloadGeneration(generation)
        let downloadedIds = await downloadedSongIds(serverId: serverId)
        let succeededIds = songs.filter { downloadedIds.contains($0.id) }.map(\.id)

        var localCoverPath: String? = nil
        if let coverArtId = playlist.coverArt {
            do {
                try await _downloadCoverArt(id: coverArtId, serverId: serverId)
                localCoverPath = Self.coverStorageName(for: OriginalArtwork.storageID(coverArtId), serverId: serverId)
            } catch {
                Logger.download.error("Cover art download failed for playlist '\(playlist.id, privacy: .public)' (coverArtId: \(coverArtId, privacy: .public)): \(error, privacy: .public)")
            }
        }

        try checkDownloadGeneration(generation)
        let playlistId = playlist.id
        let playlistName = playlist.name
        let comment = playlist.comment
        let coverArt = playlist.coverArt
        let tracksSucceeded = succeededIds.count
        let totalTracks = total
        let ids = succeededIds
        let coverPath = localCoverPath

        await MainActor.run {
            guard !Task.isCancelled, serverService.state.activeServer?.id == serverId,
                  !serverService.state.isSigningOut else { return }
            let context = ModelContext(modelContainer)
            let sid = serverId
            let existing = (try? context.fetch(FetchDescriptor<DownloadedPlaylist>(predicate: #Predicate {
                $0.playlistId == playlistId && $0.serverId == sid
            })))?.first

            if let existing {
                existing.tracksCount = tracksSucceeded
                existing.totalTracksCount = totalTracks
                existing.downloadedAt = Date()
                existing.songIds = ids
                if let coverPath { existing.localCoverArtPath = coverPath }
            } else {
                let record = DownloadedPlaylist(
                    playlistId: playlistId,
                    serverId: serverId,
                    name: playlistName,
                    comment: comment,
                    tracksCount: tracksSucceeded,
                    totalTracksCount: totalTracks,
                    coverArtId: coverArt,
                    localCoverArtPath: coverPath,
                    songIds: ids
                )
                context.insert(record)
            }
            do {
                try context.save()
            } catch {
                Logger.download.debug("DownloadService: playlist record save failed — \(error)")
            }
        }
        try checkDownloadGeneration(generation)
        Logger.download.info("Playlist '\(playlist.id, privacy: .public)': \(tracksSucceeded)/\(total) tracks downloaded.")
        if tracksSucceeded == totalTracks, totalTracks > 0 {
            await toastService.showSuccess("\(playlist.name) downloaded")
        } else if tracksSucceeded == 0, totalTracks > 0 {
            await toastService.showError(UserFacingError.downloadFailed.displayMessage)
        }
    }

    func isDownloading(songId: String, serverId: UUID) async -> Bool {
        inFlightTasks[taskKey(songId: songId, serverId: serverId)] != nil
    }

    func isDownloadingAlbum(_ albumId: String) async -> Bool {
        guard let sid = await MainActor.run(body: { serverService.state.activeServer?.id }) else { return false }
        return albumBatchTasks[taskKey(songId: albumId, serverId: sid)] != nil
    }

    func isDownloadingPlaylist(_ playlistId: String) async -> Bool {
        guard let sid = await MainActor.run(body: { serverService.state.activeServer?.id }) else { return false }
        return playlistBatchTasks[taskKey(songId: playlistId, serverId: sid)] != nil
    }

    func cancelAlbumDownload(albumId: String, serverId: UUID) async {
        let key = taskKey(songId: albumId, serverId: serverId)
        let flight = albumBatchTasks.removeValue(forKey: key)
        flight?.task.cancel()
        _ = await flight?.task.result
    }

    func cancelPlaylistDownload(playlistId: String, serverId: UUID) async {
        let key = taskKey(songId: playlistId, serverId: serverId)
        let flight = playlistBatchTasks.removeValue(forKey: key)
        flight?.task.cancel()
        _ = await flight?.task.result
    }

    // MARK: - Cancel

    func cancelAllDownloads() async {
        if let cancellationTask { await cancellationTask.value; return }
        downloadGeneration &+= 1
        let tasks = Array(inFlightTasks.values) + Array(albumBatchTasks.values) + Array(playlistBatchTasks.values)
        let covers = Array(inFlightCoverTasks.values)
        for flight in tasks { flight.task.cancel() }
        for task in covers { task.cancel() }
        let cancellation = Task {
            for flight in tasks { _ = await flight.task.result }
            for task in covers { _ = await task.result }
            #if os(iOS)
            await self.backgroundDownloads.cancelAll()
            #endif
            self.journal.removeAll()
            self.progressContinuation?.yield([])
        }
        cancellationTask = cancellation
        await cancellation.value
        cancellationTask = nil
    }

    /// Keep submissions fenced until both transfer draining and local cleanup finish.
    func removeAllDownloads() async {
        if let cache = cacheService as? CacheService { await cache.prepareUnifiedAudio() }
        if let storageRemovalTask { await storageRemovalTask.value; return }
        let task = Task {
            await self.cancelAllDownloads()
            self.clearDownloadedStore()
            if let cache = self.cacheService as? CacheService { await cache.enforceAutomaticLimit() }
        }
        storageRemovalTask = task
        await task.value
        storageRemovalTask = nil
    }

    private func clearDownloadedStore() {
        ManagedAudioStore.shared.withLock {
            do {
                if !usesUnifiedAudio, FileManager.default.fileExists(atPath: downloadsDirectory.path) {
                    try FileManager.default.removeItem(at: downloadsDirectory)
                }
                try FileManager.default.createDirectory(at: downloadsDirectory, withIntermediateDirectories: true)
                let context = ModelContext(modelContainer)
                if usesUnifiedAudio {
                    for asset in try context.fetch(FetchDescriptor<CachedTrack>()) { asset.isPinned = false }
                }
                try context.delete(model: DownloadedTrack.self)
                try context.delete(model: DownloadedAlbum.self)
                try context.delete(model: DownloadedPlaylist.self)
                try context.save()
            } catch {
                // Retain metadata if cleanup fails; file availability checks hide invalid rows.
                Logger.download.error("Could not clear offline downloads: \(error.localizedDescription)")
            }
        }
    }

    func cancelDownload(songId: String, serverId: UUID) async {
        journal.remove(songID: songId, serverID: serverId)
        let key = taskKey(songId: songId, serverId: serverId)
        inFlightTasks.removeValue(forKey: key)?.task.cancel()
        #if os(iOS)
        backgroundDownloads.cancel(clientKey: key)
        #endif
    }

    func currentDownloadGeneration() -> UInt64 { downloadGeneration }

    /// Repair/add batches also share the cancellation epoch and the current power budget.
    func downloadSongs(_ songs: [Song], serverId: UUID) async throws -> Int {
        try await downloadSongs(songs, serverId: serverId, generation: downloadGeneration)
    }

    func downloadSongs(_ songs: [Song], serverId: UUID, generation: UInt64) async throws -> Int {
        try checkDownloadGeneration(generation)
        return try await DownloadBatchRunner.run(songs, shouldContinue: {
            await self.downloadGenerationIsCurrent(generation)
        }) { song in
            do {
                try await self.checkDownloadGeneration(generation)
                try await self.download(song: song, serverId: serverId)
                return true
            } catch { return false }
        }
    }

    private func downloadGenerationIsCurrent(_ generation: UInt64) -> Bool {
        !Task.isCancelled && generation == downloadGeneration && cancellationTask == nil && storageRemovalTask == nil
    }

    private func checkDownloadGeneration(_ generation: UInt64) throws {
        guard downloadGenerationIsCurrent(generation) else { throw CancellationError() }
    }

    private func awaitOwnedDownload(_ task: Task<Void, Error>) async throws {
        try await withTaskCancellationHandler {
            try await task.value
            try Task.checkCancellation()
        } onCancel: { task.cancel() }
    }

    private func runBatch(key: String, playlist: Bool, operation: @escaping @Sendable () async throws -> Void) async throws {
        if let existing = playlist ? playlistBatchTasks[key] : albumBatchTasks[key], !existing.task.isCancelled {
            try await existing.task.value
            try Task.checkCancellation()
            return
        }
        let id = UUID()
        let task = Task {
            defer {
                if playlist {
                    if self.playlistBatchTasks[key]?.id == id { self.playlistBatchTasks[key] = nil }
                } else if self.albumBatchTasks[key]?.id == id { self.albumBatchTasks[key] = nil }
            }
            try Task.checkCancellation()
            try await operation()
        }
        let flight = Flight(id: id, task: task)
        if playlist { playlistBatchTasks[key] = flight } else { albumBatchTasks[key] = flight }
        try await awaitOwnedDownload(task)
    }

    private func removeUnreferencedAudio(_ path: String) {
        ManagedAudioStore.shared.withLock {
            let url = downloadsDirectory.appendingPathComponent(path)
            guard !ManagedAudioStore.shared.isLeased(url) else { return }
            let context = ModelContext(modelContainer)
            let pins = (try? context.fetch(FetchDescriptor<DownloadedTrack>())) ?? []
            guard !pins.contains(where: { $0.filePath == path }) else { return }
            if usesUnifiedAudio {
                let assets = (try? context.fetch(FetchDescriptor<CachedTrack>())) ?? []
                guard !assets.contains(where: { $0.filePath == path }) else { return }
            }
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Remove

    func remove(songId: String, serverId: UUID) async throws {
        if let cache = cacheService as? CacheService { await cache.prepareUnifiedAudio() }
        let storedTrack: (filePath: String, albumId: String?)? = await MainActor.run {
            let context = ModelContext(modelContainer)
            let predicate = #Predicate<DownloadedTrack> { $0.songId == songId }
            let tracks = (try? context.fetch(FetchDescriptor(predicate: predicate))) ?? []
            return tracks.first(where: { $0.serverId == serverId }).map { ($0.filePath, $0.albumId) }
        }
        let unified = usesUnifiedAudio
        try await MainActor.run {
            try ManagedAudioStore.shared.withLock {
                let context = ModelContext(modelContainer)
                let tracks = try context.fetch(FetchDescriptor<DownloadedTrack>(predicate: #Predicate {
                    $0.songId == songId && $0.serverId == serverId
                }))
                tracks.forEach { context.delete($0) }
                if unified {
                    let assets = try context.fetch(FetchDescriptor<CachedTrack>(predicate: #Predicate {
                        $0.songId == songId && $0.serverId == serverId
                    }))
                    assets.forEach { $0.isPinned = false }
                }
                try context.save()
            }
        }
        if !unified, let storedTrack { removeUnreferencedAudio(storedTrack.filePath) }
        if let cache = cacheService as? CacheService { await cache.enforceAutomaticLimit() }
        // A logical album can retain tracks from another physical album. Reconcile its
        // manifest before deciding that removal of the final stereo track removed the album.
        await MainActor.run {
            let context = ModelContext(modelContainer)
            let sid = serverId
            let remaining = (try? context.fetch(FetchDescriptor<DownloadedTrack>(predicate: #Predicate { $0.serverId == sid }))) ?? []
            let remainingIDs = Set(remaining.flatMap {
                [$0.songId, $0.currentRemoteID].compactMap { $0 } + ($0.legacyRemoteIDs ?? [])
            })
            let albums = (try? context.fetch(FetchDescriptor<DownloadedAlbum>(predicate: #Predicate { $0.serverId == sid }))) ?? []
            for album in albums where album.albumId == storedTrack?.albumId || album.songIds?.contains(songId) == true {
                let count = album.songIds.map { $0.filter(remainingIDs.contains).count }
                    ?? remaining.filter { $0.albumId == album.albumId }.count
                if count == 0 { context.delete(album) } else { album.tracksCount = count }
            }
            try? context.save()
        }
        // Sync DownloadedPlaylist.songIds — remove this songId from any playlist that contains it.
        // Without this, the cold-start retry would re-download the song silently after removal.
        await MainActor.run {
            let context = ModelContext(modelContainer)
            let sid = serverId
            let playlists = (try? context.fetch(
                FetchDescriptor<DownloadedPlaylist>(predicate: #Predicate { $0.serverId == sid })
            )) ?? []
            var didMutate = false
            for playlist in playlists where playlist.songIds.contains(songId) {
                playlist.songIds.removeAll { $0 == songId }
                playlist.tracksCount = playlist.songIds.count
                didMutate = true
            }
            if didMutate {
                do {
                    try context.save()
                } catch {
                    Logger.download.debug("DownloadService: remove playlist sync save failed — \(error)")
                }
            }
        }
    }

    func remove(albumId: String, serverId: UUID) async throws {
        let songIds: [String] = await MainActor.run {
            let context = ModelContext(modelContainer)
            let sid = serverId
            let albums = (try? context.fetch(FetchDescriptor<DownloadedAlbum>(predicate: #Predicate { $0.serverId == sid }))) ?? []
            let playlists = (try? context.fetch(FetchDescriptor<DownloadedPlaylist>(predicate: #Predicate { $0.serverId == sid }))) ?? []
            let tracks = (try? context.fetch(FetchDescriptor<DownloadedTrack>(predicate: #Predicate { $0.serverId == sid }))) ?? []
            let mine = albums.filter { $0.albumId == albumId }
            let owned = Set(mine.flatMap { $0.songIds ?? [] })
                .union(tracks.filter { $0.albumId == albumId }.map(\.songId))
            let otherAlbums = albums.filter { $0.albumId != albumId }
            let shared = Set(otherAlbums.flatMap { $0.songIds ?? [] } + playlists.flatMap(\.songIds))
            let otherAlbumIDs = Set(otherAlbums.map(\.albumId))
            let purge = tracks.filter {
                owned.contains($0.songId) && !shared.contains($0.songId)
                    && !($0.albumId.map(otherAlbumIDs.contains) ?? false)
            }.map(\.songId)
            mine.forEach { context.delete($0) }
            try? context.save()
            return purge
        }
        for songId in songIds { try? await remove(songId: songId, serverId: serverId) }
    }

    func remove(playlistId: String, serverId: UUID) async throws {
        // Refcount-safe LOCAL purge (mirrors remove(albumId:)): delete the playlist record AND the track files it
        // owns — but KEEP any file still referenced by another downloaded playlist or a downloaded album, so a
        // song shared between two playlists survives until the LAST one is removed. Purely local: never touches
        // the server, so purging an orphan whose playlist is already gone is safe and idempotent.
        let songsToPurge: [String] = await MainActor.run {
            let context = ModelContext(modelContainer)
            let sid = serverId
            let allPlaylists = (try? context.fetch(FetchDescriptor<DownloadedPlaylist>(
                predicate: #Predicate { $0.serverId == sid }
            ))) ?? []
            let mine = allPlaylists.filter { $0.playlistId == playlistId }
            let owned = Set(mine.flatMap { $0.songIds })
            // Songs still referenced by ANOTHER downloaded playlist on this server → keep their files.
            let sharedByOtherPlaylist = Set(
                allPlaylists.filter { $0.playlistId != playlistId }.flatMap { $0.songIds }
            )
            // Albums downloaded on this server → keep any of their tracks (don't break a co-downloaded album).
            let albums = (try? context.fetch(FetchDescriptor<DownloadedAlbum>(
                predicate: #Predicate { $0.serverId == sid }
            ))) ?? []
            let downloadedAlbumIds = Set(albums.map(\.albumId))
            let logicalAlbumSongs = Set(albums.flatMap { $0.songIds ?? [] })
            let allTracks = (try? context.fetch(FetchDescriptor<DownloadedTrack>(
                predicate: #Predicate { $0.serverId == sid }
            ))) ?? []
            let albumIdBySong = Dictionary(
                allTracks.filter { owned.contains($0.songId) }
                    .compactMap { track -> (String, String)? in
                        guard let albumId = track.albumId else { return nil }
                        return (track.songId, albumId)
                    },
                uniquingKeysWith: { first, _ in first }
            )
            let toPurge = owned.filter { songId in
                if sharedByOtherPlaylist.contains(songId) || logicalAlbumSongs.contains(songId) { return false }
                if let albumId = albumIdBySong[songId], downloadedAlbumIds.contains(albumId) { return false }
                return true
            }
            // Delete the playlist record FIRST so remove(songId:)'s playlist-sync is a no-op for it.
            mine.forEach { context.delete($0) }
            do {
                try context.save()
            } catch {
                Logger.download.debug("DownloadService: remove playlist save failed — \(error)")
            }
            return Array(toPurge)
        }
        // Delete the files + DownloadedTrack records for the non-shared songs (local + idempotent).
        for songId in songsToPurge {
            try? await remove(songId: songId, serverId: serverId)
        }
    }

    // MARK: - Helpers

    private func taskKey(songId: String, serverId: UUID) -> String {
        "\(songId)::\(serverId.uuidString)"
    }

    /// Returns one stable request per artwork identity, preserving album-first ordering. A track
    /// whose cover equals the album cover adds no work; only genuinely different track covers do.
    nonisolated static func albumCoverArtIDs(
        albumCoverArtID: String?,
        songCoverArtIDs: [String?]
    ) -> [String] {
        ArtworkIdentity.distinct(([albumCoverArtID] + songCoverArtIDs).compactMap { $0 })
    }

    private func emit(progress: DownloadProgress) {
        progressContinuation?.yield([progress])
        if progress.progress >= 1 {
            Task { @MainActor in
                NotificationCenter.default.post(name: .cassetteDownloadCompleted, object: nil)
            }
        }
    }

    /// Downloads original bytes to `coverArtsDirectory/<id>@original-v1`, independently of streaming caches.
    /// Throws on network or write error — callers must catch and treat as best-effort.
    private func _downloadCoverArt(id: String, serverId: UUID) async throws {
        let normalizedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty else { return }
        let identity = try await MainActor.run { try serverService.state.requestIdentity(for: serverId) }
        let generation = downloadGeneration
        let storageID = Self.coverStorageName(for: OriginalArtwork.storageID(normalizedID), serverId: serverId)
        let fileURL = coverArtsDirectory.appendingPathComponent(storageID)
        guard !FileManager.default.fileExists(atPath: fileURL.path) else {
            Logger.download.debug("Cover art '\(normalizedID, privacy: .public)' already on disk — skipping.")
            return
        }

        if let loader = originalArtworkLoader.withLock({ $0 }) {
            guard await loader(normalizedID, serverId),
                  await MainActor.run(body: { serverService.state.requestIsCurrent(identity) }) else {
                throw CancellationError()
            }
            try checkDownloadGeneration(generation)
            return
        }

        if let existing = inFlightCoverTasks[storageID] {
            try await existing.value
            return
        }

        let task = Task<Void, Error> {
            try await self._fetchAndStoreCoverArt(id: normalizedID, fileURL: fileURL, identity: identity, generation: generation)
        }
        inFlightCoverTasks[storageID] = task
        defer { inFlightCoverTasks.removeValue(forKey: storageID) }
        try await awaitOwnedDownload(task)
    }

    private func _fetchAndStoreCoverArt(id: String, fileURL: URL, identity: ServerRequestIdentity, generation: UInt64) async throws {
        // Another completed request may have installed the file while this task waited to enter
        // the actor. Recheck immediately before performing network work.
        guard !FileManager.default.fileExists(atPath: fileURL.path) else { return }

        let context = try await serverService.requestContext(serverID: identity.serverID)
        guard context.identity == identity else { throw CancellationError() }
        let creds = context.credentials
        let client = context.client
        // Request the ORIGINAL (full-resolution) cover — no server-side `size` downscale —
        // so offline album art is stored at its highest quality.
        guard let artURL = client.coverArtURL(id: id, size: nil) else {
            throw CassetteError.mediaNotFound(songId: id)
        }

        var request = URLRequest(url: artURL)
        ArtworkNetworkPolicy.apply(to: &request)
        for (k, v) in creds.customHeaders { request.setValue(v, forHTTPHeaderField: k) }

        let (data, response) = try await coverSession.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            struct HTTPError: Error & Sendable { let statusCode: Int }
            throw CassetteError.downloadFailed(songId: id, underlying: HTTPError(statusCode: code))
        }
        guard await Task.detached(priority: .utility, operation: {
            ArtworkImageCache.thumbnailImage(from: data, maxDimension: 8) != nil
        }).value else { throw URLError(.cannotDecodeContentData) }

        try Task.checkCancellation()
        try checkDownloadGeneration(generation)
        guard await MainActor.run(body: { serverService.state.requestIsCurrent(identity) }) else { throw CancellationError() }
        try checkDownloadGeneration(generation)
        // Persist the original bytes verbatim — no JPEG re-encode, no low-resolution decode.
        try FileManager.default.createDirectory(at: coverArtsDirectory, withIntermediateDirectories: true)
        try ArtworkContentStore.write(data, to: fileURL)
        await MainActor.run { NotificationCenter.default.post(name: OriginalArtwork.didInstall, object: id) }
        Logger.download.info("Cover art '\(id, privacy: .public)' downloaded (\(data.count) bytes, original)")
    }
}
