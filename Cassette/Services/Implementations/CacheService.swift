// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import SwiftData
import OSLog

/// Streaming cache for recently-played tracks. FIFO eviction removes the oldest files until
/// their total size fits the user-selected storage capacity.
///
/// Distinct from DownloadService:
/// - DownloadService → permanent, user-explicit, never auto-evicted, lives in Documents/.
/// - CacheService → transient, automatic, evicted by FIFO, lives in Caches/.
///
/// Populated via the streaming hook in PlayerService (phase 2). MediaResolver reads from this cache
/// between permanent downloads and remote streaming.
actor CacheService: CacheServiceProtocol {
    private let modelContainer: ModelContainer
    private let mediaIdentityService: MediaIdentityService?
    private let cacheDirectory: URL
    private(set) var maxBytes: Int64

    nonisolated static let defaultMaxBytes: Int64 = 2 * 1_024 * 1_024 * 1_024
    nonisolated static let minMaxBytes: Int64 = 512 * 1_024 * 1_024
    nonisolated static let maxMaxBytes: Int64 = 16 * 1_024 * 1_024 * 1_024

    init(
        modelContainer: ModelContainer,
        maxBytes: Int64 = CacheService.defaultMaxBytes,
        cacheDirectory: URL? = nil,
        mediaIdentityService: MediaIdentityService? = nil
    ) {
        self.modelContainer = modelContainer
        self.mediaIdentityService = mediaIdentityService
        self.maxBytes = max(Self.minMaxBytes, min(Self.maxMaxBytes, maxBytes))

        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        self.cacheDirectory = cacheDirectory
            ?? caches.appendingPathComponent("app.cassette/audio", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: self.cacheDirectory, withIntermediateDirectories: true)
        } catch {
            Logger.cache.debug("CacheService: failed to create cache directory — \(error)")
        }
    }

    // MARK: - Configuration

    /// Updates the byte capacity and immediately evicts oldest entries when necessary.
    func setMaxBytes(_ value: Int64) async {
        maxBytes = max(Self.minMaxBytes, min(Self.maxMaxBytes, value))
        await evictToFitLimit()
    }

    // MARK: - Lookup

    func cachedURL(forSongId songId: String, serverId: UUID) async -> URL? {
        let candidates = await MainActor.run {
            mediaIdentityService?.candidateRemoteIDs(for: songId, serverId: serverId, entityType: .song) ?? [songId]
        }
        let candidateSet = Set(candidates)
        let entry: (filePath: String, fileSize: Int64)? = await MainActor.run {
            let context = ModelContext(modelContainer)
            let sid = serverId
            let descriptor = FetchDescriptor<CachedTrack>(predicate: #Predicate { $0.serverId == sid })
            let tracks = (try? context.fetch(descriptor)) ?? []
            return tracks.first(where: { candidateSet.contains($0.songId) }).map { ($0.filePath, $0.fileSize) }
        }
        guard let entry else { return nil }
        let url = cacheDirectory.appendingPathComponent(entry.filePath)
        // Self-healing covers missing, empty, and size-mismatched files — a partial or
        // corrupt cache file must fall through to stream, never reach the player.
        let diskSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        guard diskSize > 0, diskSize == entry.fileSize else {
            Logger.cache.warning("Cache record exists but file missing or invalid (disk \(diskSize) bytes, record \(entry.fileSize)): \(entry.filePath, privacy: .public)")
            await invalidate(songId: songId, serverId: serverId)
            return nil
        }
        return url
    }

    func touch(songId: String, serverId: UUID) async {
        // No-op now that LRU is removed. Kept for MediaResolver API stability (phase 5 removes it).
    }

    // MARK: - Storage

    /// Stores audio data in the cache. Upserts the SwiftData record, then runs FIFO eviction.
    func store(data: Data, forSongId songId: String, serverId: UUID, mimeType: String) async throws -> URL {
        let ext = audioExtension(mimeType: mimeType)
        let relativePath = "\(serverId.uuidString)-\(songId).\(ext)"
        let fileURL = cacheDirectory.appendingPathComponent(relativePath)

        try data.write(to: fileURL, options: .atomic)
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? Int64(data.count)

        try await registerFile(fileURL, size: fileSize, songId: songId, serverId: serverId, mimeType: mimeType)
        return fileURL
    }

    func store(fileAt sourceURL: URL, forSongId songId: String, serverId: UUID, mimeType: String) async throws -> URL {
        try Task.checkCancellation()
        let fileURL = cacheDirectory.appendingPathComponent("\(serverId.uuidString)-\(songId).\(audioExtension(mimeType: mimeType))")
        let stagingURL = cacheDirectory.appendingPathComponent(".import-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: stagingURL) }
        // Copy into the destination filesystem before atomically publishing it. A failed copy
        // or cancelled download must never replace a complete, playable cache entry.
        try FileManager.default.copyItem(at: sourceURL, to: stagingURL)
        let size = (try FileManager.default.attributesOfItem(atPath: stagingURL.path)[.size] as? Int64) ?? 0
        guard size > 0 else { throw CocoaError(.fileReadCorruptFile) }
        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: fileURL.path) {
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: stagingURL)
        } else {
            try FileManager.default.moveItem(at: stagingURL, to: fileURL)
        }
        try await registerFile(fileURL, size: size, songId: songId, serverId: serverId, mimeType: mimeType)
        return fileURL
    }

    private func registerFile(_ fileURL: URL, size fileSize: Int64, songId: String, serverId: UUID, mimeType: String) async throws {
        let relativePath = fileURL.lastPathComponent

        try await MainActor.run {
            let context = ModelContext(modelContainer)
            let sid = serverId
            let existing = (try? context.fetch(FetchDescriptor<CachedTrack>(predicate: #Predicate {
                $0.songId == songId && $0.serverId == sid
            })))?.first
            if let existing {
                existing.filePath = relativePath
                existing.fileSize = fileSize
                existing.mimeType = mimeType
                existing.cachedAt = Date()
            } else {
                context.insert(CachedTrack(
                    songId: songId,
                    serverId: serverId,
                    filePath: relativePath,
                    fileSize: fileSize,
                    mimeType: mimeType
                ))
            }
            try context.save()
        }

        await evictToFitLimit()
        Logger.cache.info("Cached '\(songId, privacy: .public)' (\(fileSize) bytes, \(mimeType, privacy: .public))")
    }

    private func audioExtension(mimeType: String) -> String {
        switch mimeType.lowercased() {
        case "audio/mpeg", "audio/mp3":          return "mp3"
        case "audio/flac", "audio/x-flac":       return "flac"
        case "audio/mp4", "audio/m4a",
             "audio/aac", "audio/x-aac":         return "m4a"
        case "audio/ogg":                         return "ogg"
        case "audio/opus":                        return "opus"
        case "audio/wav", "audio/x-wav":         return "wav"
        case "audio/aiff", "audio/x-aiff":       return "aiff"
        default:                                  return "bin"
        }
    }

    // MARK: - Eviction

    /// FIFO eviction: removes oldest tracks until the remaining recorded bytes fit.
    private func evictToFitLimit() async {
        let limit = maxBytes

        let toEvict: [(filePath: String, recordId: UUID)] = await MainActor.run {
            let context = ModelContext(modelContainer)
            let descriptor = FetchDescriptor<CachedTrack>(
                sortBy: [SortDescriptor(\.cachedAt, order: .forward)]
            )
            let tracks = (try? context.fetch(descriptor)) ?? []
            var remaining = tracks.reduce(Int64(0)) { $0 + max(0, $1.fileSize) }
            guard remaining > limit else { return [] }
            var victims: [(String, UUID)] = []
            for track in tracks where remaining > limit {
                victims.append((track.filePath, track.id))
                remaining -= max(0, track.fileSize)
            }
            return victims
        }

        guard !toEvict.isEmpty else { return }

        for entry in toEvict {
            do {
                try FileManager.default.removeItem(at: cacheDirectory.appendingPathComponent(entry.filePath))
            } catch {
                Logger.cache.debug("CacheService: evict removeItem failed — \(error)")
            }
        }

        let recordIds = Set(toEvict.map(\.recordId))
        await MainActor.run {
            let context = ModelContext(modelContainer)
            let allTracks = (try? context.fetch(FetchDescriptor<CachedTrack>())) ?? []
            allTracks.filter { recordIds.contains($0.id) }.forEach { context.delete($0) }
            do {
                try context.save()
            } catch {
                Logger.cache.debug("CacheService: evict save failed — \(error)")
            }
        }

        Logger.cache.info("Evicted \(toEvict.count) cache entries (FIFO, oldest first)")
    }

    /// Manually invalidates a single entry (file + record). No-op if not cached.
    func invalidate(songId: String, serverId: UUID) async {
        let filePath: String? = await MainActor.run {
            let context = ModelContext(modelContainer)
            let sid = serverId
            let tracks = (try? context.fetch(FetchDescriptor<CachedTrack>(predicate: #Predicate {
                $0.songId == songId && $0.serverId == sid
            }))) ?? []
            return tracks.first?.filePath
        }
        if let filePath {
            do {
                try FileManager.default.removeItem(at: cacheDirectory.appendingPathComponent(filePath))
            } catch {
                Logger.cache.debug("CacheService: invalidate removeItem failed — \(error)")
            }
        }
        await MainActor.run {
            let context = ModelContext(modelContainer)
            let sid = serverId
            let tracks = (try? context.fetch(FetchDescriptor<CachedTrack>(predicate: #Predicate {
                $0.songId == songId && $0.serverId == sid
            }))) ?? []
            tracks.forEach { context.delete($0) }
            do {
                try context.save()
            } catch {
                Logger.cache.debug("CacheService: invalidate save failed — \(error)")
            }
        }
        Logger.cache.debug("Invalidated cache for '\(songId, privacy: .public)'")
    }

    /// Clears the entire cache (all servers).
    func clearAll() async {
        let allFilePaths: [String] = await MainActor.run {
            let context = ModelContext(modelContainer)
            let tracks = (try? context.fetch(FetchDescriptor<CachedTrack>())) ?? []
            return tracks.map(\.filePath)
        }
        for filePath in allFilePaths {
            do {
                try FileManager.default.removeItem(at: cacheDirectory.appendingPathComponent(filePath))
            } catch {
                Logger.cache.debug("CacheService: clearAll removeItem failed — \(error)")
            }
        }
        await MainActor.run {
            let context = ModelContext(modelContainer)
            let tracks = (try? context.fetch(FetchDescriptor<CachedTrack>())) ?? []
            tracks.forEach { context.delete($0) }
            do {
                try context.save()
            } catch {
                Logger.cache.debug("CacheService: clearAll tracks save failed — \(error)")
            }
        }
        await MainActor.run {
            let context = ModelContext(modelContainer)
            let lyrics = (try? context.fetch(FetchDescriptor<CachedLyrics>())) ?? []
            lyrics.forEach { context.delete($0) }
            do {
                try context.save()
            } catch {
                Logger.cache.debug("CacheService: clearAll lyrics save failed — \(error)")
            }
        }
        Logger.cache.info("Cleared all cache entries")
    }

    /// Clears streaming audio files and `CachedTrack` rows; leaves `CachedLyrics` intact.
    func clearAudioTracksOnly() async {
        let allFilePaths: [String] = await MainActor.run {
            let context = ModelContext(modelContainer)
            let tracks = (try? context.fetch(FetchDescriptor<CachedTrack>())) ?? []
            return tracks.map(\.filePath)
        }
        for filePath in allFilePaths {
            try? FileManager.default.removeItem(at: cacheDirectory.appendingPathComponent(filePath))
        }
        await MainActor.run {
            let context = ModelContext(modelContainer)
            let tracks = (try? context.fetch(FetchDescriptor<CachedTrack>())) ?? []
            tracks.forEach { context.delete($0) }
            try? context.save()
        }
        Logger.cache.info("Cleared audio streaming cache")
    }

    /// Clears SwiftData lyrics payloads only.
    func clearLyricsCache() async {
        await MainActor.run {
            let context = ModelContext(modelContainer)
            let lyrics = (try? context.fetch(FetchDescriptor<CachedLyrics>())) ?? []
            lyrics.forEach { context.delete($0) }
            try? context.save()
        }
        Logger.cache.info("Cleared lyrics cache")
    }

    var lyricsUsedBytes: Int64 {
        get async {
            await MainActor.run {
                let context = ModelContext(modelContainer)
                let lyrics = (try? context.fetch(FetchDescriptor<CachedLyrics>())) ?? []
                return lyrics.reduce(Int64(0)) { $0 + Int64($1.jsonPayload.count) }
            }
        }
    }

    var lyricsCount: Int {
        get async {
            await MainActor.run {
                let context = ModelContext(modelContainer)
                let lyrics = (try? context.fetch(FetchDescriptor<CachedLyrics>())) ?? []
                return lyrics.count
            }
        }
    }

    /// Clears all cache entries for a specific server (used at server switch in phase 6).
    func clearAllForServer(_ serverId: UUID) async {
        let filePaths: [String] = await MainActor.run {
            let context = ModelContext(modelContainer)
            let tracks = (try? context.fetch(FetchDescriptor<CachedTrack>())) ?? []
            return tracks.filter { $0.serverId == serverId }.map(\.filePath)
        }
        for filePath in filePaths {
            do {
                try FileManager.default.removeItem(at: cacheDirectory.appendingPathComponent(filePath))
            } catch {
                Logger.cache.debug("CacheService: clearAllForServer removeItem failed — \(error)")
            }
        }
        await MainActor.run {
            let context = ModelContext(modelContainer)
            let tracks = (try? context.fetch(FetchDescriptor<CachedTrack>())) ?? []
            tracks.filter { $0.serverId == serverId }.forEach { context.delete($0) }
            do {
                try context.save()
            } catch {
                Logger.cache.debug("CacheService: clearAllForServer tracks save failed — \(error)")
            }
        }
        await MainActor.run {
            let context = ModelContext(modelContainer)
            let lyrics = (try? context.fetch(FetchDescriptor<CachedLyrics>())) ?? []
            lyrics.filter { $0.serverId == serverId }.forEach { context.delete($0) }
            do {
                try context.save()
            } catch {
                Logger.cache.debug("CacheService: clearAllForServer lyrics save failed — \(error)")
            }
        }
        Logger.cache.info("Cleared cache for server \(serverId.uuidString)")
    }

    // MARK: - Reporting

    /// Total bytes used by all cached tracks. Used by Settings UI.
    var usedBytes: Int64 {
        get async {
            await MainActor.run {
                let context = ModelContext(modelContainer)
                let tracks = (try? context.fetch(FetchDescriptor<CachedTrack>())) ?? []
                return tracks.map(\.fileSize).reduce(0, +)
            }
        }
    }

    /// Number of cached tracks. Used by Settings UI.
    var trackCount: Int {
        get async {
            await MainActor.run {
                let context = ModelContext(modelContainer)
                let tracks = (try? context.fetch(FetchDescriptor<CachedTrack>())) ?? []
                return tracks.count
            }
        }
    }
}
