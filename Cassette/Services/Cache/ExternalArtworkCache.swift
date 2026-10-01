// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import CryptoKit
import OSLog
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Fetcher protocol (testability seam)

nonisolated protocol ExternalArtworkFetcher: Sendable {
    func fetchData(from url: URL) async throws -> Data
}

nonisolated struct URLSessionExternalFetcher: ExternalArtworkFetcher {
    private let session: URLSession

    nonisolated init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.httpMaximumConnectionsPerHost = 2
        session = URLSession(configuration: config)
    }

    func fetchData(from url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}

// MARK: - Cache actor

/// Disk + memory cache for external cover art (e.g. Cover Art Archive).
/// Resolution order: memory LRU → disk (Caches/app.cassette/external-covers/) → network.
/// Disk entries expire after 90 days; GC enforces a 100 MB size cap on top of TTL.
actor ExternalArtworkCache {

    // MARK: - Configuration

    private let ttl: TimeInterval
    private let maxSizeBytes: Int64

    // MARK: - Storage

    private let cacheDirectory: URL
    private let fetcher: any ExternalArtworkFetcher
    private let decodeGate = CoverDecodeGate(limit: 2)

    // MARK: - Memory cache (LRU, keyed by URL)

    private var memoryCache: CostBoundedCache<URL, PlatformImage>
    private var inFlight: [URL: Task<PlatformImage?, Never>] = [:]
    private var cacheGeneration = 0
    private var isClearingCache = false

    // MARK: - Init

    init(
        cacheDirectory: URL? = nil,
        fetcher: (any ExternalArtworkFetcher)? = nil,
        ttl: TimeInterval = 90 * 24 * 3600,
        maxSizeBytes: Int64 = 100 * 1024 * 1024,
        maxMemoryEntries: Int = 30,
        maxMemoryBytes: Int = 24 * 1024 * 1024
    ) {
        let dir: URL
        if let cacheDirectory {
            dir = cacheDirectory
        } else {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            dir = caches.appendingPathComponent("app.cassette/external-covers", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.cacheDirectory = dir
        self.fetcher = fetcher ?? URLSessionExternalFetcher()
        self.ttl = ttl
        self.maxSizeBytes = maxSizeBytes
        self.memoryCache = CostBoundedCache(countLimit: maxMemoryEntries, costLimit: maxMemoryBytes)
    }

    // MARK: - Public API

    func image(for url: URL) async -> PlatformImage? {
        guard !isClearingCache else { return nil }
        // 1. Memory hit
        if let hit = memoryCache.value(forKey: url) {
            Logger.externalArtwork.debug("ExternalArtworkCache: memory hit \(url.lastPathComponent, privacy: .public)")
            return hit
        }

        if let task = inFlight[url] { return await task.value }
        let generation = cacheGeneration
        let fileURL = diskURL(for: url)
        let task = Task.detached(priority: .utility) { [fetcher, ttl, decodeGate] () -> PlatformImage? in
            // Keep disk reads, image decoding and writes off the UI and cache actors.
            await decodeGate.acquire()
            let diskImage = Task.isCancelled ? nil : Self.diskImage(at: fileURL, ttl: ttl)
            await decodeGate.release()
            guard !Task.isCancelled else { return nil }
            if let diskImage { return diskImage }
            do {
                let data = try await fetcher.fetchData(from: url)
                await decodeGate.acquire()
                let image = Task.isCancelled ? nil : ArtworkImageCache.thumbnailImage(
                        from: data, maxDimension: ArtworkTier.hero.decodePixels
                )
                await decodeGate.release()
                guard !Task.isCancelled, let image else { return nil }
                try? data.write(to: fileURL, options: .atomic)
                return image
            } catch {
                Logger.externalArtwork.debug("ExternalArtworkCache: fetch failed for \(url, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
        inFlight[url] = task
        let image = await task.value
        inFlight[url] = nil
        if let image, generation == cacheGeneration {
            memoryCache.insert(image, forKey: url, cost: image.decodedMemoryCost)
        }
        return image
    }

    func clearMemoryCache() {
        cacheGeneration &+= 1
        memoryCache.removeAll()
    }

    /// Wipes memory + on-disk external artwork (developer / Settings reset).
    func clearAll() async {
        guard !isClearingCache else { return }
        isClearingCache = true
        defer { isClearingCache = false }
        clearMemoryCache()
        // Drain pending writes before deleting files, so a reset cannot repopulate the disk cache.
        let pending = Array(inFlight.values)
        for task in pending { task.cancel() }
        for task in pending { _ = await task.value }
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else { return }
        for url in contents {
            try? fm.removeItem(at: url)
        }
        Logger.externalArtwork.info("ExternalArtworkCache: cleared all entries")
    }

    // MARK: - Garbage collection

    /// Purges expired files (modification date > TTL), then enforces the size cap
    /// by deleting the oldest surviving files until total is under maxSizeBytes.
    func runGarbageCollection() {
        let fm = FileManager.default
        let resourceKeys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        guard let contents = try? fm.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: Array(resourceKeys),
            options: .skipsHiddenFiles
        ) else { return }

        let expiryDate = Date(timeIntervalSinceNow: -ttl)
        var survivors: [(url: URL, modDate: Date, size: Int64)] = []
        var expiredCount = 0

        // Phase 1: TTL purge
        for fileURL in contents {
            let values = try? fileURL.resourceValues(forKeys: resourceKeys)
            let modDate = values?.contentModificationDate ?? .distantPast
            let size = Int64(values?.fileSize ?? 0)

            if modDate < expiryDate {
                try? fm.removeItem(at: fileURL)
                expiredCount += 1
            } else {
                survivors.append((fileURL, modDate, size))
            }
        }

        // Phase 2: size cap — delete oldest first until total <= maxSizeBytes
        let totalSize = survivors.reduce(0) { $0 + $1.size }
        var capRemovedCount = 0
        if totalSize > maxSizeBytes {
            let sorted = survivors.sorted { $0.modDate < $1.modDate }
            var runningSize = totalSize
            for entry in sorted {
                guard runningSize > maxSizeBytes else { break }
                try? fm.removeItem(at: entry.url)
                runningSize -= entry.size
                capRemovedCount += 1
            }
        }

        Logger.externalArtwork.info("ExternalArtworkCache: GC done — \(expiredCount) expired, \(capRemovedCount) over cap")
    }

    // MARK: - Private helpers

    private func diskURL(for url: URL) -> URL {
        cacheDirectory.appendingPathComponent(sha256(url.absoluteString) + ".jpg")
    }

    nonisolated private static func diskImage(at fileURL: URL, ttl: TimeInterval) -> PlatformImage? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        guard let modDate = attrs?[.modificationDate] as? Date,
              Date().timeIntervalSince(modDate) < ttl,
              let data = try? Data(contentsOf: fileURL),
              let image = ArtworkImageCache.thumbnailImage(
                from: data, maxDimension: ArtworkTier.hero.decodePixels
              ) else {
            return nil
        }
        return image
    }

    private func sha256(_ string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
