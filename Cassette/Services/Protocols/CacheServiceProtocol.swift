// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation

protocol CacheServiceProtocol: AnyObject, Sendable {
    var usedBytes: Int64 { get async }
    var trackCount: Int { get async }
    var reclaimableBytes: Int64 { get async }

    func cachedURL(forSongId songId: String, serverId: UUID) async -> URL?

    /// No-op since LRU removal. Kept for MediaResolver API stability — removed in phase 5.
    func touch(songId: String, serverId: UUID) async
    func storeTransferred(fileAt sourceURL: URL, forSongId songId: String, serverId: UUID,
                          mimeType: String, key: MediaTransferKey) async throws -> URL
    func recordTransfer(_ key: MediaTransferKey) async
    func completedTransfer(for key: MediaTransferKey) async -> CachedMediaTransfer?

    func store(data: Data, forSongId songId: String, serverId: UUID, mimeType: String) async throws -> URL

    /// Imports a completed download without loading the entire audio file into memory.
    /// The caller retains ownership of the source file until this call returns.
    func store(fileAt sourceURL: URL, forSongId songId: String, serverId: UUID, mimeType: String) async throws -> URL

    /// Updates the maximum cache size. Triggers FIFO eviction when total bytes exceed it.
    func setMaxBytes(_ value: Int64) async

    /// Removes a single record and its file immediately (e.g. on stale-file detection).
    func invalidate(songId: String, serverId: UUID) async
    func invalidate(songId: String, serverId: UUID, matching url: URL) async

    /// Deletes every cached track and file — called by "Clear cache now".
    func clearAll() async

    /// Deletes streaming audio cache only (keeps lyrics cache).
    func clearAudioTracksOnly() async

    /// Deletes cached lyrics payloads only.
    func clearLyricsCache() async

    var lyricsUsedBytes: Int64 { get async }
    var lyricsCount: Int { get async }

    /// Deletes all cached tracks for a specific server — called at server switch (phase 6).
    func clearAllForServer(_ serverId: UUID) async
}

extension CacheServiceProtocol {
    var reclaimableBytes: Int64 { get async { await usedBytes } }
    func invalidate(songId: String, serverId: UUID, matching url: URL) async {
        await invalidate(songId: songId, serverId: serverId)
    }
    func storeTransferred(fileAt sourceURL: URL, forSongId songId: String, serverId: UUID,
                          mimeType: String, key: MediaTransferKey) async throws -> URL {
        let url = try await store(fileAt: sourceURL, forSongId: songId, serverId: serverId, mimeType: mimeType)
        await recordTransfer(key)
        return url
    }
    func recordTransfer(_ key: MediaTransferKey) async {}
    func completedTransfer(for key: MediaTransferKey) async -> CachedMediaTransfer? { nil }
}
