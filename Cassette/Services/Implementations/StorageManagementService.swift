// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import SwiftData

struct StorageCategorySnapshot: Identifiable, Sendable, Equatable {
    enum Kind: String, Sendable, CaseIterable {
        case audioCache
        case lyrics
        case artwork
        case descriptions
        case translations
        case discover
        case downloads
    }

    let kind: Kind
    let title: String
    let subtitle: String?
    let byteCount: Int64
    let itemCount: Int?

    var id: String { kind.rawValue }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }
}

// MARK: - Paths & sizing

private nonisolated enum StoragePaths {
    static let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    static let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    static let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

    static let descriptions = caches.appendingPathComponent("app.cassette/descriptions", isDirectory: true)
    static let externalCovers = caches.appendingPathComponent("app.cassette/external-covers", isDirectory: true)
    static let translations = applicationSupport.appendingPathComponent("LyricsTranslations", isDirectory: true)
    static let discoverCache = applicationSupport
        .appendingPathComponent("app.cassette/discover-sections-cache.json")
    static let streamingCoverArts = documents.appendingPathComponent("app.cassette/coverarts", isDirectory: true)

    static func directoryByteCount(
        at url: URL,
        where predicate: (URL) -> Bool = { _ in true }
    ) -> Int64 {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys)
        ) else { return 0 }

        var total: Int64 = 0
        var seenFiles = Set<String>()
        for case let fileURL as URL in enumerator where predicate(fileURL) {
            let values = try? fileURL.resourceValues(forKeys: keys)
            if values?.isRegularFile == true {
                if let identity = ArtworkContentStore.fileIdentity(fileURL),
                   !seenFiles.insert(identity).inserted { continue }
                total += Int64(values?.fileSize ?? 0)
            }
        }
        return total
    }

    static func fileByteCount(at url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values?.isRegularFile == true else { return 0 }
        return Int64(values?.fileSize ?? 0)
    }

    static func removeFiles(at url: URL, where predicate: (URL) -> Bool) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil
        ) else { return }
        for fileURL in entries where predicate(fileURL) {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }
}

/// Aggregates on-device cache sizes and per-category clear actions (iPhone Storage–style).
actor StorageManagementService {
    private let modelContainer: ModelContainer
    private let cacheService: any CacheServiceProtocol
    private let downloadService: any DownloadServiceProtocol
    private let externalArtworkCache: ExternalArtworkCache
    private let artworkImageCache: ArtworkImageCache
    private let dominantColorExtractor: DominantColorExtractor
    private let albumCoverPreloadService: AlbumCoverPreloadService?
    private let coverArtsDirectory: URL

    init(
        modelContainer: ModelContainer,
        cacheService: any CacheServiceProtocol,
        downloadService: any DownloadServiceProtocol,
        externalArtworkCache: ExternalArtworkCache,
        artworkImageCache: ArtworkImageCache,
        dominantColorExtractor: DominantColorExtractor,
        albumCoverPreloadService: AlbumCoverPreloadService? = nil,
        coverArtsDirectory: URL? = nil
    ) {
        self.modelContainer = modelContainer
        self.cacheService = cacheService
        self.downloadService = downloadService
        self.externalArtworkCache = externalArtworkCache
        self.artworkImageCache = artworkImageCache
        self.dominantColorExtractor = dominantColorExtractor
        self.albumCoverPreloadService = albumCoverPreloadService
        self.coverArtsDirectory = coverArtsDirectory ?? StoragePaths.streamingCoverArts
    }

    func categories() async -> [StorageCategorySnapshot] {
        async let audioBytes = cacheService.usedBytes
        async let audioCount = cacheService.trackCount
        async let lyricsBytes = cacheService.lyricsUsedBytes
        async let lyricsCount = cacheService.lyricsCount
        async let downloadTotals = downloadTotals()

        let artworkBytes = StoragePaths.directoryByteCount(at: coverArtsDirectory) { url in
            !url.lastPathComponent.hasPrefix(".")
        } + StoragePaths.directoryByteCount(at: StoragePaths.externalCovers)

        let (_, downloadCount) = await downloadTotals

        return [
            .init(
                kind: .audioCache,
                title: String(localized: "Music", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
                subtitle: String(localized: "\(downloadCount) saved songs · automatic storage and saved music", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
                byteCount: await audioBytes,
                itemCount: await audioCount
            ),
            .init(
                kind: .lyrics,
                title: String(localized: "Lyrics Cache", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
                subtitle: String(localized: "Synced lyrics from your server", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
                byteCount: await lyricsBytes,
                itemCount: await lyricsCount
            ),
            .init(
                kind: .artwork,
                title: String(localized: "Artwork Cache", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
                subtitle: String(localized: "Cover art and thumbnails", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
                byteCount: artworkBytes,
                itemCount: nil
            ),
            .init(
                kind: .descriptions,
                title: String(localized: "Album & Artist Descriptions", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
                subtitle: String(localized: "Wikipedia and MusicBrainz text", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
                byteCount: StoragePaths.directoryByteCount(at: StoragePaths.descriptions),
                itemCount: nil
            ),
            .init(
                kind: .translations,
                title: String(localized: "Translation Cache", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
                subtitle: String(localized: "Cached lyric translations", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
                byteCount: StoragePaths.directoryByteCount(at: StoragePaths.translations),
                itemCount: nil
            ),
            .init(
                kind: .discover,
                title: String(localized: "Discover Cache", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
                subtitle: String(localized: "Home screen recommendations", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
                byteCount: StoragePaths.fileByteCount(at: StoragePaths.discoverCache),
                itemCount: nil
            ),

        ]
    }

    var reclaimableAudioBytes: Int64 { get async { await cacheService.reclaimableBytes } }

    func clear(_ kind: StorageCategorySnapshot.Kind) async {
        switch kind {
        case .audioCache:
            await cacheService.clearAudioTracksOnly()
        case .lyrics:
            await cacheService.clearLyricsCache()
        case .artwork:
            await clearArtworkCaches()
        case .descriptions:
            await DescriptionCache.shared.clear()
        case .translations:
            await MainActor.run { TranslationCache.shared.clear() }
        case .discover:
            await clearDiscoverCache()
        case .downloads:
            await clearAllDownloads()
        }
    }

    nonisolated static func isCachedArtwork(_ url: URL) -> Bool {
        ["@thumb", "@hero", "@original-v1"].contains { url.lastPathComponent.hasSuffix($0) }
    }

    func clearArtworkCaches() async {
        // Drain both foreground workers and the background daemon before deleting files.
        do { try await albumCoverPreloadService?.suspendForAccountReset() }
        catch {
            await albumCoverPreloadService?.finishAccountReset()
            return
        }
        await MainActor.run {
            dominantColorExtractor.clearCache()
            artworkImageCache.clearCache()
        }
        await externalArtworkCache.clearAll()
        StoragePaths.removeFiles(at: coverArtsDirectory) { url in
            Self.isCachedArtwork(url)
        }
        await MainActor.run {
            albumCoverPreloadService?.finishAccountReset()
            albumCoverPreloadService?.reconcileChangedCovers()
        }
    }

    // MARK: - Private

    private struct DownloadedTrackRef: Sendable {
        let songId: String
        let serverId: UUID
        let fileSize: Int64
    }

    private struct DownloadedAlbumRef: Sendable {
        let albumId: String
        let serverId: UUID
    }

    private func downloadTotals() async -> (Int64, Int) {
        let tracks = await downloadedTracks()
        let bytes = tracks.map(\.fileSize).reduce(Int64(0), +)
        return (bytes, tracks.count)
    }

    private func downloadedTracks() async -> [DownloadedTrackRef] {
        await MainActor.run {
            let context = ModelContext(modelContainer)
            let tracks = (try? context.fetch(FetchDescriptor<DownloadedTrack>())) ?? []
            return tracks.map {
                DownloadedTrackRef(songId: $0.songId, serverId: $0.serverId, fileSize: $0.fileSize)
            }
        }
    }

    private func clearAllDownloads() async {
        if let downloads = downloadService as? DownloadService {
            await downloads.removeAllDownloads()
            return
        }
        let albums = await MainActor.run { () -> [DownloadedAlbumRef] in
            let context = ModelContext(modelContainer)
            let fetched = (try? context.fetch(FetchDescriptor<DownloadedAlbum>())) ?? []
            return fetched.map {
                DownloadedAlbumRef(albumId: $0.albumId, serverId: $0.serverId)
            }
        }
        for album in albums {
            try? await downloadService.remove(albumId: album.albumId, serverId: album.serverId)
        }
        for track in await downloadedTracks() {
            try? await downloadService.remove(songId: track.songId, serverId: track.serverId)
        }
        await MainActor.run {
            let context = ModelContext(modelContainer)
            try? context.delete(model: DownloadedPlaylist.self)
            try? context.save()
        }
    }

    private func clearDiscoverCache() async {
        await MainActor.run { DiscoverSectionsCache.clear() }
    }
}
