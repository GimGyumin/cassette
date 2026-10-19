// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import MediaPlayer
import OSLog
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Loads and caches artwork images for MPNowPlayingInfoCenter.
/// Isolated actor so concurrent artwork fetches don't race on the cache dictionary.
actor ArtworkLoader {
    /// Request identity includes the URL and credentials for both caching and coalescing.
    /// A fetch that failed without credentials must not suppress a later
    /// authenticated retry for the same URL (Cloudflare-protected hosts answer
    /// 403 until the cover header is attached).
    private struct RequestKey: Hashable {
        let url: URL
        let credentials: Int
    }

    private var cache = CostBoundedCache<RequestKey, MPMediaItemArtwork>(
        countLimit: 8, costLimit: 24 * 1024 * 1024
    )
    private var inFlight: [RequestKey: Task<(MPMediaItemArtwork, Int)?, Never>] = [:]
    private var failedLoadUntil: [RequestKey: Date] = [:]
    private var cacheGeneration = 0
    private let session: URLSession
    private static let networkFailureCooldown: TimeInterval = 60

    init(session: URLSession? = nil) {
        let config = URLSessionConfiguration.default
        ArtworkNetworkPolicy.configure(config)
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 30
        config.httpMaximumConnectionsPerHost = 2
        self.session = session ?? URLSession(configuration: config)
    }

    /// Returns cached artwork if available, otherwise fetches from `url` injecting
    /// `headers` into the request (required for Cloudflare-protected hosts).
    func artwork(for url: URL, headers: [String: String]) async -> MPMediaItemArtwork? {
        let key = RequestKey(url: url, credentials: Self.credentialSignature(headers))
        if let cached = cache.value(forKey: key) { return cached }
        if let task = inFlight[key] {
            let generation = cacheGeneration
            let result = await task.value?.0
            return generation == cacheGeneration ? result : nil
        }
        if shouldSkipNetworkFetch(key) { return nil }

        // This loader serves only Now Playing, not library prefetching.
        let generation = cacheGeneration
        var request = URLRequest(url: url)
        ArtworkNetworkPolicy.apply(to: &request)
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let task = Task.detached(priority: .utility) { [session, request] () -> (MPMediaItemArtwork, Int)? in
            do {
                let data: Data
                if url.isFileURL {
                    data = try Data(contentsOf: url)
                } else {
                    let (bytes, response) = try await session.data(for: request)
                    guard let http = response as? HTTPURLResponse,
                          (200..<300).contains(http.statusCode) else { return nil }
                    data = bytes
                }
                guard let image = ArtworkImageCache.thumbnailImage(
                    from: data, maxDimension: ArtworkTier.hero.decodePixels
                ) else { return nil }
                let artwork = Self.makeArtwork(image)
                return (artwork, image.decodedMemoryCost)
            } catch {
                Logger.artworkCache.debug("ArtworkLoader: artwork load failed: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
        inFlight[key] = task
        let result = await task.value
        guard generation == cacheGeneration else { return nil }
        inFlight[key] = nil
        guard let (artwork, cost) = result else {
            if !url.isFileURL { rememberNetworkFailure(key) }
            return nil
        }
        if generation == cacheGeneration {
            failedLoadUntil[key] = nil
            cache.insert(artwork, forKey: key, cost: cost)
        }
        return artwork
    }

    func clearCache() {
        cacheGeneration &+= 1
        for task in inFlight.values { task.cancel() }
        inFlight.removeAll()
        cache.removeAll()
        failedLoadUntil.removeAll()
    }

    private func shouldSkipNetworkFetch(_ key: RequestKey) -> Bool {
        guard !key.url.isFileURL, let retryDate = failedLoadUntil[key] else { return false }
        if retryDate > Date() { return true }
        failedLoadUntil[key] = nil
        return false
    }

    private func rememberNetworkFailure(_ key: RequestKey) {
        failedLoadUntil[key] = Date().addingTimeInterval(Self.networkFailureCooldown)
    }

    /// Order-independent, non-reversible signature of a header set. Used only as an
    /// in-memory dictionary key — never logged or persisted.
    nonisolated static func credentialSignature(_ headers: [String: String]) -> Int {
        var hasher = Hasher()
        for key in headers.keys.sorted() {
            hasher.combine(key)
            hasher.combine(headers[key])
        }
        return hasher.finalize()
    }

    nonisolated static func makeArtwork(_ image: PlatformImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { requestedSize in
            guard requestedSize.width.isFinite, requestedSize.height.isFinite,
                  requestedSize.width > 0, requestedSize.height > 0,
                  image.size.width > 0, image.size.height > 0 else { return image }
            let scale = min(1, requestedSize.width / image.size.width, requestedSize.height / image.size.height)
            return image.resized(maxDimension: max(1, max(image.size.width, image.size.height) * scale))
        }
    }
}
