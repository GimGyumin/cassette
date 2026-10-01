// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import ImageIO
import OSLog
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - ArtworkTier

/// Named decode resolution tier for cover art.
///
/// Tier determines both the pixel dimension passed to CGImageSourceCreateThumbnailAtIndex
/// and the disk/RAM cache key suffix (`id@thumb`, `id@hero`).
nonisolated enum ArtworkTier: String, Sendable {
    /// 240 px — list rows, grid cells, queue rows, mini player, Wrapped cards.
    case thumb
    /// 1200 px — detail view heroes, full-player cover, lock screen artwork.
    case hero

    var decodePixels: Int {
        switch self {
        case .thumb: return 240
        case .hero: return 1200
        }
    }
}

// MARK: - CoverFetchGate

/// Limits concurrent server cover fetches so they cannot saturate the TCP connection pool
/// shared with the active audio stream. Uses a continuation-based semaphore so callers
/// are suspended (not blocked) while waiting for a slot.
private actor CoverFetchGate {
    private let limit: Int
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = limit; available = limit }

    func acquire() async {
        if available > 0 { available -= 1; return }
        Logger.artworkCache.debug("[NET-COVER] gate: queued (limit=\(self.limit) busy, waiters=\(self.waiters.count + 1))")
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume()
            // available unchanged — slot transferred directly to the waiter
        } else {
            available += 1
        }
    }
}

/// Caps parallel ImageIO thumbnails — unbounded disk decode stampedes starve audio (~5s spikes in logs).
actor CoverDecodeGate {
    private let limit: Int
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = limit; available = limit }

    func acquire() async {
        if available > 0 { available -= 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume()
        } else {
            available += 1
        }
    }
}

// MARK: - ArtworkImageCache

/// Shared in-memory cache for cover art PlatformImages, keyed by `"\(coverArtId)@\(tier)"`.
///
/// Two decode tiers keep memory and decode cost proportional to display context:
///   • thumb (240 px) — list rows, grid cells, Wrapped cards, mini player
///   • hero  (1200 px) — detail view heroes, full-player cover, lock screen artwork
///
/// Both tiers for the same id can coexist in RAM. LRU eviction is unified across tiers;
/// a byte budget prevents hero images from occupying hundreds of MB.
///
/// Resolution order: permanent original/download → RAM → tiered disk cache → server.
///
/// Original/downloaded bytes are preserved separately; UI surfaces decode bounded thumbnails
/// from those bytes through a concurrency gate. Streaming derivatives are fallback caches only.
@MainActor
@Observable
final class ArtworkImageCache {
    /// Not observed — CoverArtView copies results into `@State`. Observing this dictionary
    /// invalidated every parent that touched the cache (Home destinations, Discover, etc.).
    @ObservationIgnored
    private var cache = CostBoundedCache<String, PlatformImage>(
        countLimit: 110, costLimit: 48 * 1024 * 1024
    )
    @ObservationIgnored
    private var cacheGeneration = 0
    @ObservationIgnored private var localImageSources: [String: String] = [:]
    /// Coalesces concurrent `load` calls for the same tier key (Home + Discover often
    /// request the same album thumb twice → duplicate network + flaky ImageIO decode).
    @ObservationIgnored
    private var inFlight: [String: Task<PlatformImage?, Never>] = [:]
    @ObservationIgnored
    private var failedNetworkLoadUntil: [String: Date] = [:]
    nonisolated private static let networkFailureCooldown: TimeInterval = 60

    private let downloadService: any DownloadServiceProtocol
    private let libraryService: any LibraryServiceProtocol
    private let serverService: (any ServerServiceProtocol)?
    private let session: URLSession
    // Caps in-flight server cover fetches to prevent saturating the TCP connection pool.
    private let fetchGate = CoverFetchGate(limit: 2)
    private let decodeGate = CoverDecodeGate(limit: 2)

    init(downloadService: any DownloadServiceProtocol, libraryService: any LibraryServiceProtocol, serverService: (any ServerServiceProtocol)? = nil, session: URLSession? = nil) {
        self.downloadService = downloadService
        self.libraryService = libraryService
        self.serverService = serverService
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 30
        config.httpMaximumConnectionsPerHost = 2
        self.session = session ?? URLSession(configuration: config)
    }

    // MARK: - Public API

    /// Returns the cached image for the given tier synchronously, or nil if not yet loaded.
    /// Does not trigger a fetch — call load(coverArtId:tier:) for that.
    func cached(for coverArtId: String?, tier: ArtworkTier = .thumb) -> PlatformImage? {
        guard let coverArtId else { return nil }
        let key = cacheKey(id: coverArtId, tier: tier)
        guard let image = cache[key] else { return nil }
        touch(key)
        return image
    }

    /// Read-only sync lookup — no LRU touch, no fetch.
    func cachedImage(for id: String, tier: ArtworkTier = .thumb) -> PlatformImage? {
        cache[cacheKey(id: id, tier: tier)]
    }

    /// Returns the image from cache if available; otherwise fetches from disk or (optionally) server.
    /// The `tier` determines both decode resolution and which disk/RAM bucket is checked.
    /// Set `allowNetwork` to `false` for offline fallbacks — disk only, no HTTP.
    @discardableResult
    func load(
        coverArtId: String?,
        tier: ArtworkTier = .thumb,
        allowNetwork: Bool = true,
        playbackPriority: Bool = false
    ) async -> PlatformImage? {
        guard let coverArtId else { return nil }

        let key = cacheKey(id: coverArtId, tier: tier)

        // Original/downloaded artwork is authoritative, even if an older streaming thumbnail is in RAM.
        if let local = await loadPlainDiskCover(coverArtId: coverArtId, tier: tier) { return local }

        // 1. RAM hit.
        if let hit = cache[key] {
            touch(key)
            return hit
        }

        // Join an in-flight load for the same key instead of starting a duplicate fetch.
        let flightKey = "\(key)#\(allowNetwork)#\(playbackPriority)"
        if let existing = inFlight[flightKey] {
            return await existing.value
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return nil as PlatformImage? }
            defer { self.inFlight[flightKey] = nil }
            return await self.loadUncached(
                coverArtId: coverArtId,
                key: key,
                tier: tier,
                allowNetwork: allowNetwork,
                playbackPriority: playbackPriority
            )
        }
        inFlight[flightKey] = task
        return await task.value
    }

    /// Downloads the ORIGINAL (full-resolution) cover art from the server and persists it as
    /// a separate original file, caching a 1200 px decode in RAM for immediate hero surfaces.
    /// Used by the library-wide album-cover preloader so artwork is stored at its highest
    /// quality — no server-side `size` downscale and no JPEG re-encode.
    @discardableResult
    func downloadOriginalAndCacheAsHero(coverArtId: String) async -> Bool {
        let generation = cacheGeneration
        let key = cacheKey(id: coverArtId, tier: .hero)

        // Only a verified original counts as a completed download; tiered caches may be resized.
        let tieredDiskId = OriginalArtwork.storageID(coverArtId)
        if await downloadService.localCoverArtURL(forId: tieredDiskId) != nil { return true }

        if shouldSkipNetworkFetch(forKey: key) { return false }
        guard let serverURL = await libraryService.coverArtURL(id: coverArtId, size: nil) else { return false }

        await fetchGate.acquire()
        defer { await fetchGate.release() }
        guard !Task.isCancelled else { return false }

        let data: Data
        do {
            let (bytes, response) = try await session.data(for: artworkRequest(url: serverURL))
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                rememberNetworkFailure(forKey: key)
                return false
            }
            guard Self.looksLikeImageData(bytes) else {
                rememberNetworkFailure(forKey: key)
                return false
            }
            data = bytes
        } catch {
            if !Self.isCancellation(error) { rememberNetworkFailure(forKey: key) }
            return false
        }

        // Decode a hero thumbnail for immediate RAM display (ImageIO reads only what it needs).
        await decodeGate.acquire()
        let image: PlatformImage? = await Task.detached(priority: .utility) {
            ArtworkImageCache.thumbnailImage(from: data, maxDimension: ArtworkTier.hero.decodePixels)
        }.value
        await decodeGate.release()
        guard let image, generation == cacheGeneration, !Task.isCancelled else { return false }
        // Validate with ImageIO, then save the response verbatim. Never promote a resized @hero file.
        await downloadService.persistCover(data, forId: tieredDiskId)
        guard let originalURL = await downloadService.localCoverArtURL(forId: tieredDiskId),
              generation == cacheGeneration, !Task.isCancelled else { return false }
        for tier in [ArtworkTier.thumb, .hero] {
            let oldKey = cacheKey(id: coverArtId, tier: tier)
            cache.removeValue(forKey: oldKey)
            localImageSources[oldKey] = nil
        }
        failedNetworkLoadUntil[key] = nil
        store(image: image, forKey: key, generation: generation)
        localImageSources[key] = originalURL.path
        NotificationCenter.default.post(name: OriginalArtwork.didInstall, object: coverArtId)
        Logger.artworkCache.debug(
            "[NET-COVER] original done id=\(coverArtId, privacy: .public) bytes=\(data.count, privacy: .public)"
        )
        return await downloadService.localCoverArtURL(forId: tieredDiskId) != nil
    }

    private func artworkRequest(url: URL) async -> URLRequest {
        var request = URLRequest(url: url)
        if let credentials = try? await serverService?.activeCredentials() {
            for (key, value) in credentials.customHeaders { request.setValue(value, forHTTPHeaderField: key) }
        }
        return request
    }

    /// Coalesced, bounded decode of an original or legacy offline download (no network).
    func loadPlainDiskCover(coverArtId: String, tier: ArtworkTier) async -> PlatformImage? {
        let generation = cacheGeneration
        let key = cacheKey(id: coverArtId, tier: tier)
        let originalURL = await downloadService.localCoverArtURL(forId: OriginalArtwork.storageID(coverArtId))
        let localURL: URL
        if let originalURL { localURL = originalURL }
        else if let legacy = await downloadService.localCoverArtURL(forId: coverArtId) { localURL = legacy }
        else { return nil }
        if localImageSources[key] == localURL.path, let hit = cache[key] {
            touch(key)
            return hit
        }
        guard generation == cacheGeneration, !Task.isCancelled else { return nil }
        let flightKey = "local#\(key)#\(localURL.path)"
        if let existing = inFlight[flightKey] { return await existing.value }
        let task = Task { @MainActor [weak self] () -> PlatformImage? in
            guard let self else { return nil }
            defer { self.inFlight[flightKey] = nil }
            await self.decodeGate.acquire()
            let image = await Task.detached(priority: .utility) {
                guard let data = try? Data(contentsOf: localURL), !data.isEmpty else { return nil as PlatformImage? }
                return ArtworkImageCache.thumbnailImage(from: data, maxDimension: tier.decodePixels)
            }.value
            await self.decodeGate.release()
            guard generation == self.cacheGeneration, !Task.isCancelled else { return nil }
            if let image {
                self.localImageSources[key] = localURL.path
                self.store(image: image, forKey: key, generation: generation)
            }
            return image
        }
        inFlight[flightKey] = task
        return await task.value
    }

    private func loadUncached(
        coverArtId: String,
        key: String,
        tier: ArtworkTier,
        allowNetwork: Bool,
        playbackPriority: Bool
    ) async -> PlatformImage? {
        let generation = cacheGeneration
        let maxDim = tier.decodePixels

        // Another waiter may have filled RAM while we were scheduled.
        if let hit = cache[key] {
            touch(key)
            return hit
        }

        // Permanent download artwork predates the tiered cache. Resolve it before any server
        // request or derivative cache, so offline downloads remain the source of truth.
        if let downloaded = await loadPlainDiskCover(coverArtId: coverArtId, tier: tier) {
            return downloaded
        }
        guard !Task.isCancelled else { return nil }

        // 2. Disk hit — tiered file only (`{id}@thumb` / `{id}@hero`).
        let tieredDiskId = "\(coverArtId)@\(tier.rawValue)"
        if let localURL = await downloadService.localCoverArtURL(forId: tieredDiskId) {
            // Reject oversized on-disk thumbs (full-res PNG/JPEG mislabeled as @thumb).
            if let byteCount = Self.fileByteCount(at: localURL),
               Self.diskFileLooksOversized(byteCount: byteCount, tier: tier) {
                Logger.artworkCache.warning(
                    "[DISK-OVERSIZE] id=\(coverArtId, privacy: .public) tier=\(tier.rawValue, privacy: .public) bytes=\(byteCount) — removing and refetching"
                )
                await downloadService.removeCover(forId: tieredDiskId)
            } else {
                let gateStart = CFAbsoluteTimeGetCurrent()
                await decodeGate.acquire()
                let gateMs = Int((CFAbsoluteTimeGetCurrent() - gateStart) * 1000)
                let spawnStart = CFAbsoluteTimeGetCurrent()
                let diskResult = await Task.detached(priority: .utility) {
                    // `exec` exposes thread-pool starvation: on a cold start the detached body can
                    // wait for a worker, which previously showed up as "decode" cost. `wall` minus
                    // the measured work reveals descheduling mid-decode.
                    let bodyStart = CFAbsoluteTimeGetCurrent()
                    let execMs = Int((bodyStart - spawnStart) * 1000)
                    let diskStart = CFAbsoluteTimeGetCurrent()
                    guard let data = try? Data(contentsOf: localURL), !data.isEmpty else {
                        return (nil as PlatformImage?, 0, 0, false, "unknown")
                    }
                    let diskMs = Int((CFAbsoluteTimeGetCurrent() - diskStart) * 1000)
                    let decodeStart = CFAbsoluteTimeGetCurrent()
                    let image = ArtworkImageCache.thumbnailImage(from: data, maxDimension: maxDim)
                    let decodeMs = Int((CFAbsoluteTimeGetCurrent() - decodeStart) * 1000)
                    let wallMs = Int((CFAbsoluteTimeGetCurrent() - bodyStart) * 1000)
                    let slow = wallMs + gateMs > 800
                    let isJPEG = data.count >= 2 && data[0] == 0xFF && data[1] == 0xD8
                    let uti = ArtworkImageCache.imageUTIHint(for: data)
                    if slow {
                        Logger.artworkCache.warning(
                            "[DISK-SLOW] id=\(coverArtId, privacy: .public) tier=\(tier.rawValue, privacy: .public) gate=\(gateMs)ms exec=\(execMs)ms disk=\(diskMs)ms decode=\(decodeMs)ms wall=\(wallMs)ms bytes=\(data.count) uti=\(uti, privacy: .public)"
                        )
                    } else {
                        Logger.artworkCache.debug(
                            "[DISK] id=\(coverArtId, privacy: .public) tier=\(tier.rawValue, privacy: .public) gate=\(gateMs)ms exec=\(execMs)ms disk=\(diskMs)ms decode=\(decodeMs)ms wall=\(wallMs)ms bytes=\(data.count)"
                        )
                    }
                    return (image, decodeMs, data.count, !isJPEG || slow, uti)
                }.value
                await decodeGate.release()
                if let image = diskResult.0 {
                    guard generation == cacheGeneration, !Task.isCancelled else { return nil }
                    store(image: image, forKey: key, generation: generation)
                    // Migrate non-JPEG / slow-to-decode covers to opaque downscaled JPEG once.
                    if diskResult.3 {
                        Task { [weak self] in
                            let jpeg = await Task.detached(priority: .utility) {
                                image.jpgData(quality: 0.85)
                            }.value
                            guard let self, let jpeg, generation == self.cacheGeneration,
                                  !Task.isCancelled else { return }
                            await self.downloadService.persistCover(jpeg, forId: tieredDiskId)
                        }
                    }
                    Logger.artworkCache.debug(
                        "ArtworkImageCache: disk hit \(coverArtId, privacy: .public) tier=\(tier.rawValue, privacy: .public) (\(self.cache.count, privacy: .public)/\(self.cache.countLimit, privacy: .public))"
                    )
                    return image
                }
                // Corrupt tiered file — remove so the next attempt refetches.
                await downloadService.removeCover(forId: tieredDiskId)
            }
        }

        // Full-library downloads store hero files; smaller surfaces must reuse them offline.
        if tier == .thumb,
           let heroURL = await downloadService.localCoverArtURL(forId: "\(coverArtId)@hero") {
            await decodeGate.acquire()
            let result = await Task.detached(priority: .utility) {
                guard let data = try? Data(contentsOf: heroURL),
                      let image = ArtworkImageCache.thumbnailImage(from: data, maxDimension: maxDim) else {
                    return (nil as PlatformImage?, nil as Data?)
                }
                return (image, image.jpgData(quality: 0.85))
            }.value
            await decodeGate.release()
            if let image = result.0 {
                guard generation == cacheGeneration, !Task.isCancelled else { return nil }
                if let data = result.1 { await downloadService.persistCover(data, forId: tieredDiskId) }
                store(image: image, forKey: key, generation: generation)
                return image
            }
        }

        guard allowNetwork else { return nil }

        // 3. Server fetch — never open cover-art HTTP while backgrounded (iOS deprioritizes
        // plain HTTP and it contends with the audio stream during auto-skip).
        #if os(iOS)
        if !playbackPriority, UIApplication.shared.applicationState == .background {
            Logger.artworkCache.debug(
                "[NET-COVER] skipped (background) id=\(coverArtId, privacy: .public) tier=\(tier.rawValue, privacy: .public)"
            )
            if tier == .hero {
                if let thumb = cached(for: coverArtId, tier: .thumb) { return thumb }
                return await load(coverArtId: coverArtId, tier: .thumb, allowNetwork: false)
            }
            return nil
        }
        #endif

        if shouldSkipNetworkFetch(forKey: key) {
            if tier == .hero {
                if let thumb = cached(for: coverArtId, tier: .thumb) { return thumb }
                return await load(coverArtId: coverArtId, tier: .thumb, allowNetwork: false)
            }
            return nil
        }

        await fetchGate.acquire()
        if let hit = cache[key] {
            touch(key)
            await fetchGate.release()
            return hit
        }
        Logger.artworkCache.debug("[NET-COVER] start id=\(coverArtId, privacy: .public) tier=\(tier.rawValue, privacy: .public) size=\(maxDim)px")
        let fetched = await serverFetch(coverArtId: coverArtId, key: key, tier: tier, generation: generation)
        await fetchGate.release()
        return fetched
    }

    private func serverFetch(coverArtId: String, key: String, tier: ArtworkTier, generation: Int) async -> PlatformImage? {
        let maxDim = tier.decodePixels
        guard let serverURL = await libraryService.coverArtURL(id: coverArtId, size: maxDim) else { return nil }
        let t0 = Date()
        let data: Data
        do {
            let (bytes, response) = try await session.data(for: artworkRequest(url: serverURL))
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                Logger.artworkCache.warning(
                    "[NET-COVER] failed id=\(coverArtId, privacy: .public) status=\(http.statusCode) duration=\(Int(Date().timeIntervalSince(t0) * 1000))ms"
                )
                rememberNetworkFailure(forKey: key)
                return nil
            }
            guard Self.looksLikeImageData(bytes) else {
                Logger.artworkCache.warning(
                    "[NET-COVER] failed (not image) id=\(coverArtId, privacy: .public) bytes=\(bytes.count) duration=\(Int(Date().timeIntervalSince(t0) * 1000))ms"
                )
                rememberNetworkFailure(forKey: key)
                return nil
            }
            data = bytes
        } catch {
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            if Self.isCancellation(error) {
                Logger.artworkCache.debug("[NET-COVER] cancelled id=\(coverArtId, privacy: .public) duration=\(ms)ms")
            } else {
                Logger.artworkCache.warning("[NET-COVER] failed id=\(coverArtId, privacy: .public) duration=\(ms)ms error=\(error.localizedDescription, privacy: .public)")
                rememberNetworkFailure(forKey: key)
            }
            return nil
        }
        let image: PlatformImage?
        await decodeGate.acquire()
        image = await Task.detached(priority: .utility) {
            ArtworkImageCache.thumbnailImage(from: data, maxDimension: maxDim)
        }.value
        await decodeGate.release()
        guard let image else {
            Logger.artworkCache.warning("[NET-COVER] failed (decode) id=\(coverArtId, privacy: .public) duration=\(Int(Date().timeIntervalSince(t0) * 1000))ms bytes=\(data.count)")
            return nil
        }
        // A concurrent original download takes precedence over this older network request.
        if let local = await loadPlainDiskCover(coverArtId: coverArtId, tier: tier) { return local }
        // Never persist raw server bytes — full-res PNG as @thumb causes multi-second DISK-SLOW hits.
        let persistData = await Task.detached(priority: .utility) {
            image.jpgData(quality: 0.85)
        }.value
        guard generation == cacheGeneration, !Task.isCancelled else { return nil }
        Logger.artworkCache.debug(
            "[NET-COVER] done id=\(coverArtId, privacy: .public) tier=\(tier.rawValue, privacy: .public) duration=\(Int(Date().timeIntervalSince(t0) * 1000))ms bytes=\(persistData?.count ?? 0, privacy: .public)"
        )
        failedNetworkLoadUntil[key] = nil
        store(image: image, forKey: key, generation: generation)
        if let persistData {
            await downloadService.persistCover(persistData, forId: "\(coverArtId)@\(tier.rawValue)")
        }
        return image
    }

    /// Rejects HTML error pages / empty payloads that ImageIO can't thumbnail.
    nonisolated private static func looksLikeImageData(_ data: Data) -> Bool {
        guard data.count >= 8 else { return false }
        // JPEG
        if data[0] == 0xFF, data[1] == 0xD8 { return true }
        // PNG
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return true }
        // GIF
        if data.starts(with: [0x47, 0x49, 0x46]) { return true }
        // WebP (RIFF....WEBP)
        if data.count >= 12,
           data.starts(with: [0x52, 0x49, 0x46, 0x46]),
           data[8] == 0x57, data[9] == 0x45, data[10] == 0x42, data[11] == 0x50 {
            return true
        }
        // Obvious HTML / JSON error body from reverse proxies.
        if let prefix = String(data: data.prefix(64), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            if prefix.hasPrefix("<!doctype") || prefix.hasPrefix("<html") || prefix.hasPrefix("{") {
                return false
            }
        }
        // Unknown binary — let ImageIO try.
        return true
    }

    nonisolated private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        let ns = error as NSError
        return ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled
    }

    func invalidate(for coverArtId: String) async {
        // Remove both tier RAM entries and their disk files, plus the plain-id offline file.
        for key in ["\(coverArtId)@thumb", "\(coverArtId)@hero", coverArtId, OriginalArtwork.storageID(coverArtId)] {
            cache.removeValue(forKey: key)
            localImageSources[key] = nil
            failedNetworkLoadUntil[key] = nil
            await downloadService.removeCover(forId: key)
        }
        Logger.artworkCache.debug("ArtworkImageCache: invalidated \(coverArtId, privacy: .public) (RAM + disk)")
    }

    func clearCache() {
        for task in inFlight.values { task.cancel() }
        // Visible callers may finish loading, but pre-warning work must not refill RAM.
        cacheGeneration &+= 1
        cache.removeAll()
        localImageSources.removeAll()
        failedNetworkLoadUntil.removeAll()
    }

    // MARK: - Private

    private func cacheKey(id: String, tier: ArtworkTier) -> String {
        "\(id)@\(tier.rawValue)"
    }

    private func store(image: PlatformImage, forKey key: String, generation: Int) {
        guard generation == cacheGeneration, !Task.isCancelled else { return }
        cache.insert(image, forKey: key, cost: image.decodedMemoryCost)
    }

    private func shouldSkipNetworkFetch(forKey key: String) -> Bool {
        guard let retryDate = failedNetworkLoadUntil[key] else { return false }
        if retryDate > Date() {
            Logger.artworkCache.debug("[NET-COVER] skipped recent failure key=\(key, privacy: .public)")
            return true
        }
        failedNetworkLoadUntil[key] = nil
        return false
    }

    private func rememberNetworkFailure(forKey key: String) {
        failedNetworkLoadUntil[key] = Date().addingTimeInterval(Self.networkFailureCooldown)
    }

    private func touch(_ key: String) {
        cache.touch(key)
    }

    /// Max on-disk size before we treat a tier file as a mislabeled master and delete it.
    nonisolated static func diskFileLooksOversized(byteCount: Int, tier: ArtworkTier) -> Bool {
        switch tier {
        case .thumb: return byteCount > 250_000
        // Allow full-resolution original covers persisted by the album-cover preloader
        // (JPEGs are typically <1MB, but lossless/PNG originals can be several MB).
        case .hero: return byteCount > 15_000_000
        }
    }

    nonisolated static func fileByteCount(at url: URL) -> Int? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
    }

    nonisolated static func imageUTIHint(for data: Data) -> String {
        guard data.count >= 4 else { return "unknown" }
        if data[0] == 0xFF, data[1] == 0xD8 { return "jpeg" }
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if data.starts(with: [0x47, 0x49, 0x46]) { return "gif" }
        if data.count >= 12,
           data.starts(with: [0x52, 0x49, 0x46, 0x46]),
           data[8] == 0x57, data[9] == 0x45, data[10] == 0x42, data[11] == 0x50 {
            return "webp"
        }
        return "unknown"
    }

    /// Downscale + JPEG encode for a tier — used by PlaylistCoverManager / DownloadService.
    nonisolated static func jpegDataForTier(from data: Data, tier: ArtworkTier) -> Data? {
        guard let image = thumbnailImage(from: data, maxDimension: tier.decodePixels) else {
            return nil
        }
        return image.jpgData(quality: 0.85)
    }

    /// Decodes `data` using `CGImageSourceCreateThumbnailAtIndex`, which only reads the DCT
    /// data needed for the target resolution — dramatically faster than full decode for
    /// high-res covers.
    ///
    /// Never falls back to a full-buffer `PlatformImage(data:)` for large payloads — that
    /// path was responsible for multi-second (10s+) decode stalls on cold cache.
    ///
    /// `nonisolated` so it is callable from `Task.detached` without hopping to MainActor.
    /// Internal (not private) so `CoverArtView`'s local-base fallback decodes identically.
    nonisolated static func thumbnailImage(from data: Data, maxDimension: Int) -> PlatformImage? {
        guard !data.isEmpty else { return nil }

        let sourceOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldAllowFloat: false
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary) else {
            return nil
        }

        let thumbOptions: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            // Prefer embedded thumbs first — `FromImageAlways` forces a full re-decode and
            // was responsible for multi-second PNG stalls on cold disk hits.
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) {
            return platformImage(from: cgImage)
        }

        // Fall back to always-create when no embedded thumbnail exists.
        let alwaysOptions: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, alwaysOptions as CFDictionary) {
            return platformImage(from: cgImage)
        }

        // Tiny payloads only — full decode of multi-MB cover art freezes the decode gate for seconds.
        guard data.count < 512_000 else {
            Logger.artworkCache.warning(
                "thumbnailImage: ImageIO thumb failed for \(data.count, privacy: .public) byte payload — skipping full decode"
            )
            return nil
        }
        guard let full = PlatformImage(data: data) else { return nil }
        return full.resized(maxDimension: CGFloat(maxDimension))
    }

    nonisolated private static func platformImage(from cgImage: CGImage) -> PlatformImage {
        #if canImport(UIKit)
        return UIImage(cgImage: cgImage)
        #else
        return NSImage(cgImage: cgImage, size: NSSize(width: CGFloat(cgImage.width), height: CGFloat(cgImage.height)))
        #endif
    }
}
