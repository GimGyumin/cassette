// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import SwiftData
import OSLog
import WidgetKit
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

nonisolated enum WidgetSyncError: Error {
    case sharedContainerUnavailable
}

/// Keeps the App Group shared container in sync with recently played tracks,
/// pinned items, bridged cover art (JPG 600x600 80%), and dominant colors.
///
/// Called from PlayerService (track change), PinService (pin/unpin), and
/// CassetteApp (cold start). All writes are idempotent so duplicate triggers
/// from rapid skips are safe — the throttle on reloadTimelinesIfNeeded()
/// prevents WidgetCenter spam.
actor WidgetSyncService {
    private let dominantColorExtractor: DominantColorExtractor
    private let modelContainer: ModelContainer
    private let artworkCache: ArtworkImageCache
    /// Path to Documents/app.cassette/coverarts/ — same dir used by DownloadService.
    private let coversDirectory: URL
    private let serverState: ServerState

    private var lastReloadDate: Date?
    private var lastPlayStateChangeDate: Date = .distantPast
    /// Avoid re-bridging / color work for the same cover during rapid play-state flips.
    private var lastBridgedCoverArtId: String?
    private var bridgedOriginals = Set<String>()
    private var accountGeneration: UInt64 = 0

    func clearForLogout() throws {
        accountGeneration &+= 1
        lastBridgedCoverArtId = nil
        bridgedOriginals.removeAll()
        lastReloadDate = nil
        SharedStorage.write { defaults in
            for key in [SharedStorageKey.recentlyPlayedItems, .pinnedItems, .dominantColors, .nowPlayingState] {
                defaults.removeObject(forKey: key.rawValue)
            }
            WidgetCenter.shared.reloadAllTimelines()
        }
        if let directory = SharedStorage.coverArtCacheDirectory,
           FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    init(
        dominantColorExtractor: DominantColorExtractor,
        modelContainer: ModelContainer,
        artworkCache: ArtworkImageCache,
        coversDirectory: URL,
        serverState: ServerState
    ) {
        self.dominantColorExtractor = dominantColorExtractor
        self.modelContainer = modelContainer
        self.artworkCache = artworkCache
        self.coversDirectory = coversDirectory
        self.serverState = serverState
    }

    // MARK: - Recently played + now playing

    func onTrackStarted(_ song: DisplayableSong) async {
        guard await MainActor.run(body: { serverState.activeServer != nil && !serverState.isSigningOut }) else { return }
        let coverArtId = song.coverArtId ?? song.id
        let info = SharedTrackInfo(
            id: song.id,
            title: song.title,
            artist: song.artist ?? "",
            albumID: song.albumId,
            coverArtFilename: "\(coverArtId).jpg"
        )

        // Widget timeline reads `nowPlayingState` — must update here (not only on pause/resume).
        let nowPlaying = SharedNowPlayingState(track: info, isPlaying: true, lastUpdated: Date())
        if let encoded = try? JSONEncoder().encode(nowPlaying) {
            SharedStorage.write { $0.set(encoded, forKey: SharedStorageKey.nowPlayingState.rawValue) }
        }

        var items: [SharedTrackInfo] = SharedStorage.read { defaults in
            guard let data = defaults.data(forKey: SharedStorageKey.recentlyPlayedItems.rawValue),
                  let decoded = try? JSONDecoder().decode([SharedTrackInfo].self, from: data) else {
                return []
            }
            return decoded
        }
        items.insert(info, at: 0)
        var seen = Set<String>()
        items = items.filter { seen.insert($0.id).inserted }
        if items.count > 10 { items = Array(items.prefix(10)) }

        if let encoded = try? JSONEncoder().encode(items) {
            SharedStorage.write { $0.set(encoded, forKey: SharedStorageKey.recentlyPlayedItems.rawValue) }
        }

        WidgetCenter.shared.reloadTimelines(ofKind: WidgetKind.nowPlaying)
        lastReloadDate = Date()

        try? await bridgeCoverArt(coverArtId: coverArtId, allowNetwork: false)
        await syncDominantColors(forCoverArtIds: [coverArtId])
        // Always refresh Now Playing after a track change (bypass the 2s all-timelines throttle).
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetKind.nowPlaying)
        lastReloadDate = Date()
        Logger.widget.debug("onTrackStarted: updated now playing + recently played (\(items.count) items)")
    }

    // MARK: - Now playing state

    func onPlayStateChanged(isPlaying: Bool, currentSong: DisplayableSong?) async {
        guard await MainActor.run(body: { serverState.activeServer != nil && !serverState.isSigningOut }) else { return }
        let now = Date()
        guard now.timeIntervalSince(lastPlayStateChangeDate) > 0.3 else { return }
        lastPlayStateChangeDate = now

        let track: SharedTrackInfo? = currentSong.map { song in
            let coverArtId = song.coverArtId ?? song.id
            return SharedTrackInfo(
                id: song.id,
                title: song.title,
                artist: song.artist ?? "",
                albumID: song.albumId,
                coverArtFilename: "\(coverArtId).jpg"
            )
        }
        let nowPlaying = SharedNowPlayingState(track: track, isPlaying: isPlaying, lastUpdated: Date())
        if let encoded = try? JSONEncoder().encode(nowPlaying) {
            SharedStorage.write { $0.set(encoded, forKey: SharedStorageKey.nowPlayingState.rawValue) }
        }
        let nowReload = Date()
        if lastReloadDate == nil || nowReload.timeIntervalSince(lastReloadDate!) >= 0.8 {
            lastReloadDate = nowReload
            WidgetCenter.shared.reloadTimelines(ofKind: WidgetKind.nowPlaying)
        }
        Logger.widget.debug("onPlayStateChanged: isPlaying=\(isPlaying)")
    }

    // MARK: - Pinned items

    func syncPinned() async {
        guard await MainActor.run(body: { serverState.activeServer != nil && !serverState.isSigningOut }) else { return }
        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<PinnedItem>(sortBy: [SortDescriptor(\PinnedItem.sortOrder)])
        let dbItems = (try? context.fetch(descriptor)) ?? []

        let shared: [SharedPinnedItem] = dbItems.compactMap { item in
            let kind: SharedPinnedItem.Kind
            switch item.itemType {
            case PinnedItemType.album.rawValue: kind = .album
            case PinnedItemType.playlist.rawValue: kind = .playlist
            case PinnedItemType.song.rawValue: kind = .song
            case PinnedItemType.artist.rawValue: kind = .artist
            default: return nil
            }
            return SharedPinnedItem(
                id: item.itemId,
                kind: kind,
                title: item.displayName,
                subtitle: item.displaySubtitle,
                coverArtFilename: item.coverArtId.map { "\($0).jpg" }
            )
        }

        if let encoded = try? JSONEncoder().encode(shared) {
            SharedStorage.write { $0.set(encoded, forKey: SharedStorageKey.pinnedItems.rawValue) }
        }

        let coverArtIds = dbItems.compactMap(\.coverArtId)
        for id in coverArtIds {
            try? await bridgeCoverArt(coverArtId: id)
        }
        await syncDominantColors(forCoverArtIds: coverArtIds)
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetKind.pinned)
        lastReloadDate = Date()
        Logger.widget.debug("syncPinned: wrote \(shared.count) pinned items to shared defaults")
    }

    // MARK: - Full sync (cold start)

    func fullSync() async {
        await syncPinned()

        if let items: [SharedTrackInfo] = SharedStorage.read({ defaults in
            guard let data = defaults.data(forKey: SharedStorageKey.recentlyPlayedItems.rawValue) else { return nil }
            return try? JSONDecoder().decode([SharedTrackInfo].self, from: data)
        }) {
            let ids = items.compactMap { $0.coverArtFilename.map { String($0.dropLast(4)) } }
            await syncDominantColors(forCoverArtIds: ids)
        }

        Logger.widget.debug("fullSync complete")
    }

    // MARK: - Dominant color sync

    func syncDominantColors(forCoverArtIds ids: [String]) async {
        let generation = accountGeneration
        let allCached = await dominantColorExtractor.cachedColors()
        guard generation == accountGeneration else { return }
        let filtered = allCached.filter { ids.contains($0.key) }
        guard !filtered.isEmpty else { return }
        // Merge into existing App Group dictionary — replacing wiped other covers' colors.
        SharedStorage.write { defaults in
            var merged = defaults.dictionary(forKey: SharedStorageKey.dominantColors.rawValue) as? [String: Int] ?? [:]
            for (key, value) in filtered {
                merged[key] = value
            }
            defaults.set(merged, forKey: SharedStorageKey.dominantColors.rawValue)
        }
        Logger.widget.debug("syncDominantColors: wrote \(filtered.count) colors to shared defaults")
    }

    // MARK: - Cover art bridge

    /// Copies a cover from the app's local cache into the App Group shared container
    /// as a 600×600 JPG at 80% quality. Idempotent — no-op if the file already exists.
    func bridgeCoverArt(coverArtId: String, allowNetwork: Bool = true) async throws {
        let generation = accountGeneration
        guard await MainActor.run(body: { serverState.activeServer != nil && !serverState.isSigningOut }) else { return }
        guard let sharedDir = SharedStorage.coverArtCacheDirectory else {
            throw WidgetSyncError.sharedContainerUnavailable
        }
        try SharedStorage.ensureDirectoriesExist()

        let sharedURL = sharedDir.appendingPathComponent("\(coverArtId).jpg")
        let originalPath = coversDirectory.appendingPathComponent(OriginalArtwork.storageID(coverArtId)).path
        let hasOriginal = FileManager.default.fileExists(atPath: originalPath)
        let needsOriginalUpgrade = hasOriginal && !bridgedOriginals.contains(coverArtId)
        let needsBridge = !FileManager.default.fileExists(atPath: sharedURL.path) || needsOriginalUpgrade
        let sameAsLast = lastBridgedCoverArtId == coverArtId

        // Same cover already bridged this session and file exists — skip heavy work.
        if sameAsLast, !needsBridge { return }

        // The shared cache resolves permanent originals before RAM/tiered derivatives.
        let sourceImage = await artworkCache.load(coverArtId: coverArtId, tier: .hero, allowNetwork: allowNetwork)

        guard let image = sourceImage else {
            Logger.widget.debug("bridgeCoverArt: no image available for \(coverArtId, privacy: .public)")
            return
        }

        if needsBridge {
            let jpgData = await Task.detached(priority: .utility) {
                image.resized(maxDimension: 600).jpgData(quality: 0.8)
            }.value
            if let jpgData {
                guard generation == accountGeneration else { return }
                try jpgData.write(to: sharedURL, options: .atomic)
                if hasOriginal { bridgedOriginals.insert(coverArtId) }
                Logger.widget.debug("bridgeCoverArt: bridged \(coverArtId, privacy: .public) (\(jpgData.count) bytes)")
            }
        }

        // Color extract off the main actor — MainActor only stores the packed result.
        let packed = await Task.detached(priority: .utility) {
            DominantColorExtractor.packedAverageColor(from: image)
        }.value
        guard generation == accountGeneration else { return }
        _ = await MainActor.run {
            dominantColorExtractor.storeColor(packed: packed, for: coverArtId)
        }
        lastBridgedCoverArtId = coverArtId
    }

    // MARK: - Throttled timeline reload

    /// Calls WidgetCenter.shared.reloadAllTimelines() at most once every 2 seconds.
    func reloadTimelinesIfNeeded() {
        let now = Date()
        if let last = lastReloadDate, now.timeIntervalSince(last) < 2.0 { return }
        lastReloadDate = now
        WidgetCenter.shared.reloadAllTimelines()
        Logger.widget.debug("reloadAllTimelines triggered")
    }
}
