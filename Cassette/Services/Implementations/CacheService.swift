// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import SwiftData
import OSLog
import CryptoKit
import Synchronization

/// Streaming cache for recently-played tracks. FIFO eviction removes the oldest files until
/// their total size fits the user-selected storage capacity.
///
/// One inventory and Documents audio directory serves automatic storage and saved music.
/// Pins are protected from FIFO eviction and clearing automatic storage.
///
/// Populated via the streaming hook in PlayerService (phase 2). MediaResolver reads from this cache
/// between permanent downloads and remote streaming.
actor CacheService: CacheServiceProtocol {
    private let modelContainer: ModelContainer
    private let mediaIdentityService: MediaIdentityService?
    private let cacheDirectory: URL
    private let downloadsDirectory: URL
    private let legacyDirectory: URL?
    private let legacyDownloadsDirectory: URL?
    private var migrationCompleted = false
    private(set) var maxBytes: Int64

    nonisolated static let defaultMaxBytes: Int64 = 2 * 1_024 * 1_024 * 1_024
    nonisolated static let minMaxBytes: Int64 = 512 * 1_024 * 1_024
    nonisolated static let maxMaxBytes: Int64 = 16 * 1_024 * 1_024 * 1_024

    init(
        modelContainer: ModelContainer,
        maxBytes: Int64 = CacheService.defaultMaxBytes,
        cacheDirectory: URL? = nil,
        mediaIdentityService: MediaIdentityService? = nil,
        downloadsDirectory: URL? = nil,
        legacyCacheDirectory: URL? = nil,
        legacyDownloadsDirectory: URL? = nil
    ) {
        self.modelContainer = modelContainer
        self.mediaIdentityService = mediaIdentityService
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let shared = documents.appendingPathComponent("app.cassette/audio", isDirectory: true)
        self.downloadsDirectory = downloadsDirectory ?? cacheDirectory ?? shared
        self.legacyDownloadsDirectory = legacyDownloadsDirectory ?? (cacheDirectory == nil ? documents.appendingPathComponent("app.cassette/downloads") : nil)
        self.maxBytes = max(Self.minMaxBytes, min(Self.maxMaxBytes, maxBytes))

        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        self.cacheDirectory = cacheDirectory ?? shared
        self.legacyDirectory = legacyCacheDirectory ?? (cacheDirectory == nil ? caches.appendingPathComponent("app.cassette/audio") : nil)

        do {
            try FileManager.default.createDirectory(at: self.cacheDirectory, withIntermediateDirectories: true)
            CacheDirectoryBackupPolicy.excludeFromBackup(self.cacheDirectory)
        } catch {
            Logger.cache.debug("CacheService: failed to create cache directory — \(error)")
        }
    }

    /// Preserve old assets before retiring the separate cache/download folders.
    func prepareUnifiedAudio() {
        guard !migrationCompleted else { return }
        ManagedAudioStore.shared.withLock {
            let context = ModelContext(modelContainer)
            var cached = (try? context.fetch(FetchDescriptor<CachedTrack>())) ?? []
            var retired: [URL] = []
            var needsRetry = false
            for entry in cached {
                let target = cacheDirectory.appendingPathComponent(entry.filePath)
                if !FileManager.default.fileExists(atPath: target.path), let legacyDirectory {
                    let old = legacyDirectory.appendingPathComponent(entry.filePath)
                    if FileManager.default.fileExists(atPath: old.path) {
                        try? LocalAudioFileStore.install(old, at: target, sharesImmutableSource: true)
                        if FileManager.default.fileExists(atPath: target.path) { retired.append(old) }
                        else { needsRetry = true }
                    }
                }
                if let legacyDirectory, FileManager.default.fileExists(atPath: target.path) {
                    retired.append(legacyDirectory.appendingPathComponent(entry.filePath))
                }
            }
            let pins = (try? context.fetch(FetchDescriptor<DownloadedTrack>())) ?? []
            for pin in pins {
                let target = cacheDirectory.appendingPathComponent(pin.filePath)
                if !FileManager.default.fileExists(atPath: target.path), let legacyDownloadsDirectory {
                    let old = legacyDownloadsDirectory.appendingPathComponent(pin.filePath)
                    if FileManager.default.fileExists(atPath: old.path) {
                        if (try? LocalAudioFileStore.install(old, at: target, sharesImmutableSource: true)) != nil { retired.append(old) }
                        else { needsRetry = true }
                    }
                }
                guard FileManager.default.fileExists(atPath: target.path) else { continue }
                if let legacyDownloadsDirectory { retired.append(legacyDownloadsDirectory.appendingPathComponent(pin.filePath)) }
                let entry = cached.first { $0.songId == pin.songId && $0.serverId == pin.serverId }
                    ?? CachedTrack(songId: pin.songId, serverId: pin.serverId, filePath: pin.filePath,
                                   fileSize: pin.fileSize, mimeType: pin.mimeType, cachedAt: pin.downloadedAt)
                if !cached.contains(where: { $0.id == entry.id }) { context.insert(entry); cached.append(entry) }
                if entry.filePath != pin.filePath {
                    retired.append(cacheDirectory.appendingPathComponent(entry.filePath))
                    entry.transferIdentity = nil
                }
                entry.filePath = pin.filePath; entry.fileSize = pin.fileSize; entry.mimeType = pin.mimeType
                entry.isPinned = true
            }
            do {
                try context.save()
                migrationCompleted = !needsRetry
                for old in retired { removeUnreferenced(old) }

            } catch { context.rollback() }
        }
    }

    private func removeUnreferenced(_ url: URL) {
        ManagedAudioStore.shared.withLock {
            guard !ManagedAudioStore.shared.isLeased(url) else { return }
            // Paths outside the shared directory are retired legacy aliases, not active assets.
            if url.path.hasPrefix(cacheDirectory.path + "/") {
                let context = ModelContext(modelContainer)
                let path = String(url.path.dropFirst(cacheDirectory.path.count + 1))
                let entries = (try? context.fetch(FetchDescriptor<CachedTrack>())) ?? []
                let pins = (try? context.fetch(FetchDescriptor<DownloadedTrack>())) ?? []
                guard !entries.contains(where: { $0.filePath == path }), !pins.contains(where: { $0.filePath == path }) else { return }
            }
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Configuration

    /// Updates the byte capacity and immediately evicts oldest entries when necessary.
    func setMaxBytes(_ value: Int64) async {
        maxBytes = max(Self.minMaxBytes, min(Self.maxMaxBytes, value))
        evictToFitLimit()
    }

    // MARK: - Lookup

    func cachedURL(forSongId songId: String, serverId: UUID) async -> URL? {
        prepareUnifiedAudio()
        let candidates = await mediaIdentityService?.candidateRemoteIDsInBackground(
            for: songId, serverId: serverId, entityType: .song
        ) ?? [songId]
        guard !Task.isCancelled else { return nil }
        let entry: (songId: String, filePath: String, fileSize: Int64, mimeType: String)? = {
            let context = ModelContext(modelContainer)
            let sid = serverId
            var descriptor = FetchDescriptor<CachedTrack>(predicate: #Predicate {
                $0.serverId == sid && candidates.contains($0.songId)
            })
            descriptor.fetchLimit = 1
            return (try? context.fetch(descriptor))?.first.map { ($0.songId, $0.filePath, $0.fileSize, $0.mimeType) }
        }()
        guard let entry else { return nil }
        let url = cacheDirectory.appendingPathComponent(entry.filePath)
        // Self-healing covers missing, empty, and size-mismatched files — a partial or
        // corrupt cache file must fall through to stream, never reach the player.
        let diskSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        guard diskSize > 0, diskSize == entry.fileSize else {
            Logger.cache.warning("Cache record exists but file missing or invalid (disk \(diskSize) bytes, record \(entry.fileSize)): \(entry.filePath, privacy: .public)")
            invalidate(songId: entry.songId, serverId: serverId)
            return nil
        }
        do { try LocalAudioFileStore.validate(url, size: entry.fileSize, mimeType: entry.mimeType, songID: entry.songId) }
        catch {
            Logger.cache.warning("[LOCAL-AUDIO] rejecting invalid cached payload")
            invalidate(songId: entry.songId, serverId: serverId)
            return nil
        }
        return url
    }

    func recordTransfer(_ key: MediaTransferKey) async {
        let context = ModelContext(modelContainer)
        let song = key.songID, server = key.accountID
        guard let entry = try? context.fetch(FetchDescriptor<CachedTrack>(predicate: #Predicate {
            $0.songId == song && $0.serverId == server
        })).first else { return }
        entry.transferIdentity = try? JSONEncoder().encode(key)
        try? context.save()
    }

    func completedTransfer(for key: MediaTransferKey) async -> CachedMediaTransfer? {
        let context = ModelContext(modelContainer)
        let song = key.songID, server = key.accountID
        guard let entry = try? context.fetch(FetchDescriptor<CachedTrack>(predicate: #Predicate {
            $0.songId == song && $0.serverId == server
        })).first, let identity = entry.transferIdentity,
              (try? JSONDecoder().decode(MediaTransferKey.self, from: identity)) == key else { return nil }
        let mime = entry.mimeType
        guard let url = await cachedURL(forSongId: song, serverId: server) else { return nil }
        let fresh = ModelContext(modelContainer)
        guard let current = try? fresh.fetch(FetchDescriptor<CachedTrack>(predicate: #Predicate {
            $0.songId == song && $0.serverId == server
        })).first, current.transferIdentity == identity, cacheDirectory.appendingPathComponent(current.filePath).standardizedFileURL == url.standardizedFileURL else { return nil }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        return try? CachedMediaTransfer(url: url, response: URLResponse(url: url, mimeType: mime,
            expectedContentLength: size, textEncodingName: nil))
    }

    func touch(songId: String, serverId: UUID) async {
        // No-op now that LRU is removed. Kept for MediaResolver API stability (phase 5 removes it).
    }

    // MARK: - Storage

    /// Stores audio data in the cache. Upserts the SwiftData record, then runs FIFO eviction.
    func store(data: Data, forSongId songId: String, serverId: UUID, mimeType: String) async throws -> URL {
        try Task.checkCancellation()
        guard !data.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        guard Int64(data.count) <= maxBytes else { throw CocoaError(.fileWriteOutOfSpace) }
        let ext = audioExtension(mimeType: mimeType)
        let relativePath = storageName(songId: songId, serverId: serverId) + "." + ext
        let fileURL = cacheDirectory.appendingPathComponent(relativePath)

        let staging = try StagedFileWrite.stage(data, beside: fileURL)
        defer { StagedFileWrite.discard(staging) }
        try LocalAudioFileStore.validate(staging, size: Int64(data.count), mimeType: mimeType, songID: songId)
        try ManagedAudioStore.shared.withLock {
            prepareUnifiedAudio()
            try rejectPinnedReplacement(songId: songId, serverId: serverId)
            try StagedFileWrite.commit(staging, to: fileURL)
            try registerFile(fileURL, size: Int64(data.count), songId: songId, serverId: serverId, mimeType: mimeType)
        }
        return fileURL
    }

    func store(fileAt sourceURL: URL, forSongId songId: String, serverId: UUID, mimeType: String) async throws -> URL {
        try storeFile(sourceURL, songId: songId, serverId: serverId, mimeType: mimeType, transferKey: nil)
    }

    func storeTransferred(fileAt sourceURL: URL, forSongId songId: String, serverId: UUID,
                          mimeType: String, key: MediaTransferKey) async throws -> URL {
        try storeFile(sourceURL, songId: songId, serverId: serverId, mimeType: mimeType, transferKey: key)
    }

    private func storeFile(_ sourceURL: URL, songId: String, serverId: UUID, mimeType: String,
                           transferKey: MediaTransferKey?) throws -> URL {
        try Task.checkCancellation()
        let sourceSize = (try FileManager.default.attributesOfItem(atPath: sourceURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard sourceSize > 0 else { throw CocoaError(.fileReadCorruptFile) }
        guard sourceSize <= maxBytes else { throw CocoaError(.fileWriteOutOfSpace) }
        let fileURL = cacheDirectory.appendingPathComponent(storageName(songId: songId, serverId: serverId) + "." + audioExtension(mimeType: mimeType))
        let stagingURL = cacheDirectory.appendingPathComponent(".import-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: stagingURL) }
        // Copy into the destination filesystem before atomically publishing it. A failed copy
        // or cancelled download must never replace a complete, playable cache entry.
        try LocalAudioFileStore.install(sourceURL, at: stagingURL, sharesImmutableSource: false)
        let size = (try FileManager.default.attributesOfItem(atPath: stagingURL.path)[.size] as? Int64) ?? 0
        guard size > 0 else { throw CocoaError(.fileReadCorruptFile) }
        guard size <= maxBytes else { throw CocoaError(.fileWriteOutOfSpace) }
        try LocalAudioFileStore.validate(stagingURL, size: size, mimeType: mimeType, songID: songId)
        try Task.checkCancellation()
        try ManagedAudioStore.shared.withLock {
            prepareUnifiedAudio()
            try rejectPinnedReplacement(songId: songId, serverId: serverId)
            try StagedFileWrite.commit(stagingURL, to: fileURL)
            try registerFile(fileURL, size: size, songId: songId, serverId: serverId, mimeType: mimeType, transferKey: transferKey)
        }
        return fileURL
    }

    private func storageName(songId: String, serverId: UUID) -> String {
        SHA256.hash(data: Data((serverId.uuidString + "\u{0}" + songId).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    private func rejectPinnedReplacement(songId: String, serverId: UUID) throws {
        let context = ModelContext(modelContainer)
        let pins = try context.fetch(FetchDescriptor<DownloadedTrack>(predicate: #Predicate {
            $0.songId == songId && $0.serverId == serverId
        }))
        guard pins.isEmpty else { throw CancellationError() }
    }

    private func registerFile(_ fileURL: URL, size fileSize: Int64, songId: String, serverId: UUID, mimeType: String,
                              transferKey: MediaTransferKey? = nil) throws {
        let relativePath = fileURL.lastPathComponent

        let oldPath: String? = try {
            let context = ModelContext(modelContainer)
            let sid = serverId
            let existing = try context.fetch(FetchDescriptor<CachedTrack>(predicate: #Predicate {
                $0.songId == songId && $0.serverId == sid
            })).first
            let oldPath = existing?.filePath
            if let existing {
                guard existing.isPinned != true else { throw CancellationError() }
                existing.filePath = relativePath
                existing.fileSize = fileSize
                existing.mimeType = mimeType
                existing.cachedAt = Date()
                existing.transferIdentity = try transferKey.map { try JSONEncoder().encode($0) }
            } else {
                let entry = CachedTrack(songId: songId, serverId: serverId, filePath: relativePath,
                                        fileSize: fileSize, mimeType: mimeType)
                entry.transferIdentity = try transferKey.map { try JSONEncoder().encode($0) }
                context.insert(entry)
            }
            try context.save()
            return oldPath
        }()
        if let oldPath, oldPath != relativePath {
            removeUnreferenced(cacheDirectory.appendingPathComponent(oldPath))
        }

        evictToFitLimit()
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

    /// File mutations and their short-lived contexts stay on this actor without suspension.
    /// Hopping to MainActor between the two allowed a newer store to be deleted by an older clear.
    func enforceAutomaticLimit() { evictToFitLimit() }

    private func evictToFitLimit() {
        let context = ModelContext(modelContainer)
        do {
            prepareUnifiedAudio()
            let tracks = try context.fetch(FetchDescriptor<CachedTrack>(
                sortBy: [SortDescriptor(\.cachedAt, order: .forward)]
            )).filter { $0.isPinned != true }
            var remaining = tracks.reduce(Int64(0)) { $0 + max(0, $1.fileSize) }
            var victims: [CachedTrack] = []
            for track in tracks where remaining > maxBytes {
                victims.append(track)
                remaining -= max(0, track.fileSize)
            }
            try remove(victims, in: context)
        } catch {
            Logger.cache.error("Cache eviction failed — \(error)")
        }
    }

    /// Manually invalidates a single entry (file + record). No-op if not cached.
    func invalidate(songId: String, serverId: UUID) {
        let context = ModelContext(modelContainer)
        do {
            let tracks = try context.fetch(FetchDescriptor<CachedTrack>(predicate: #Predicate {
                $0.songId == songId && $0.serverId == serverId
            }))
            try remove(tracks, in: context)
        } catch {
            Logger.cache.error("Cache invalidation failed — \(error)")
        }
    }

    /// The file path identifies legacy/renamed IDs too. Never invalidate another account
    /// or a record that now points to a different cached representation.
    func invalidate(songId: String, serverId: UUID, matching url: URL) async {
        guard url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path
            == cacheDirectory.standardizedFileURL.resolvingSymlinksInPath().path else { return }
        let path = url.lastPathComponent
        let context = ModelContext(modelContainer)
        do {
            let entries = try context.fetch(FetchDescriptor<CachedTrack>(predicate: #Predicate {
                $0.serverId == serverId && $0.filePath == path
            }))
            try remove(entries, in: context)
        } catch { Logger.cache.error("Failed cached-file invalidation: \(error)") }
    }

    /// Delete metadata first. A failed save leaves playable files intact; a failed unlink
    /// is logged rather than discarding the record before the save can be checked.
    private func remove(_ tracks: [CachedTrack], in context: ModelContext) throws {
        let ids = Set(tracks.map(\.id))
        try ManagedAudioStore.shared.withLock {
            let fresh = ModelContext(modelContainer)
            let victims = try fresh.fetch(FetchDescriptor<CachedTrack>()).filter { ids.contains($0.id) && $0.isPinned != true
                && !ManagedAudioStore.shared.isLeased(cacheDirectory.appendingPathComponent($0.filePath)) }
            let paths = Set(victims.map(\.filePath))
            victims.forEach { fresh.delete($0) }
            try fresh.save()
            for path in paths { removeUnreferenced(cacheDirectory.appendingPathComponent(path)) }
        }
    }

    func clearAll() async {
        await clearAudioTracksOnly()
        await clearLyricsCache()
    }

    func clearAudioTracksOnly() async {
        prepareUnifiedAudio()
        let context = ModelContext(modelContainer)
        do { try remove(context.fetch(FetchDescriptor<CachedTrack>()), in: context) }
        catch { Logger.cache.error("Audio cleanup failed: \(error)") }
    }

    func clearLyricsCache() async {
        let context = ModelContext(modelContainer)
        do { try context.delete(model: CachedLyrics.self); try context.save() }
        catch { Logger.cache.error("Lyrics cleanup failed: \(error)") }
    }

    func clearAllForServer(_ serverId: UUID) async {
        prepareUnifiedAudio()
        let context = ModelContext(modelContainer)
        do {
            try remove(context.fetch(FetchDescriptor<CachedTrack>(predicate: #Predicate { $0.serverId == serverId })), in: context)
            let lyrics = try context.fetch(FetchDescriptor<CachedLyrics>(predicate: #Predicate { $0.serverId == serverId }))
            lyrics.forEach { context.delete($0) }
            try context.save()
        } catch { Logger.cache.error("Server cache cleanup failed: \(error)") }
    }

    // MARK: - Reporting

    var lyricsUsedBytes: Int64 {
        get async {
            let context = ModelContext(modelContainer)
            let lyrics = (try? context.fetch(FetchDescriptor<CachedLyrics>())) ?? []
            return lyrics.reduce(Int64(0)) { $0 + Int64($1.jsonPayload.count) }
        }
    }

    var lyricsCount: Int {
        get async {
            (try? ModelContext(modelContainer).fetchCount(FetchDescriptor<CachedLyrics>())) ?? 0
        }
    }

    /// Total bytes used by all cached tracks. Used by Settings UI.
    var reclaimableBytes: Int64 {
        get async {
            prepareUnifiedAudio()
            let tracks = (try? ModelContext(modelContainer).fetch(FetchDescriptor<CachedTrack>())) ?? []
            return tracks.filter { $0.isPinned != true }.reduce(0) { $0 + $1.fileSize }
        }
    }

    var usedBytes: Int64 {
        get async {
            prepareUnifiedAudio()
            let tracks = (try? ModelContext(modelContainer).fetch(FetchDescriptor<CachedTrack>())) ?? []
            var seen = Set<String>()
            return tracks.reduce(Int64(0)) { total, track in
                let url = cacheDirectory.appendingPathComponent(track.filePath)
                guard let identity = ArtworkContentStore.fileIdentity(url), seen.insert(identity).inserted else { return total }
                return total + track.fileSize
            }
        }
    }

    var trackCount: Int {
        get async {
            prepareUnifiedAudio()
            return (try? ModelContext(modelContainer).fetchCount(FetchDescriptor<CachedTrack>())) ?? 0
        }
    }
}

/// Backup metadata can synchronously wait on filesystem services. Never perform
/// it on the caller of CacheService.init (normally MainActor), or hold the cache
/// actor while it completes. Concurrent containers share one pending operation.
private nonisolated enum CacheDirectoryBackupPolicy {
    private static let pending = Mutex<Set<URL>>([])
    private static let queue = DispatchQueue(label: "app.cassette.cache-backup-metadata", qos: .utility)

    static func excludeFromBackup(_ directory: URL) {
        guard pending.withLock({ $0.insert(directory).inserted }) else { return }
        queue.async {
            defer { _ = pending.withLock { $0.remove(directory) } }
            var url = directory
            var resources = URLResourceValues()
            resources.isExcludedFromBackup = true
            try? url.setResourceValues(resources)
        }
    }
}
