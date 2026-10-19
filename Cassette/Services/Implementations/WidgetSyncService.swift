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
    private let storageOverride: UserDefaults?

    private var lastReloadDate: Date?
    private var trailingReloadTask: Task<Void, Never>?
    private var lastPlaybackSequence: UInt64 = 0
    /// Avoid re-bridging / color work for the same cover during rapid play-state flips.
    private var lastBridgedCoverArtId: String?
    private var bridgedOriginals = Set<String>()
    private var accountGeneration: UInt64 = 0
    private var accountIdentity: ServerRequestIdentity?

    func clearForLogout() throws {
        accountGeneration &+= 1
        trailingReloadTask?.cancel()
        trailingReloadTask = nil
        accountIdentity = nil
        writeShared { $0.removeObject(forKey: "cassette.widget.server") }
        lastBridgedCoverArtId = nil
        bridgedOriginals.removeAll()
        lastReloadDate = nil
        writeShared { defaults in
            for key in [SharedStorageKey.recentlyPlayedItems, .pinnedItems, .dominantColors, .nowPlayingState] {
                defaults.removeObject(forKey: key.rawValue)
            }
            WidgetCenter.shared.reloadAllTimelines()
        }
        if storageOverride == nil, let directory = SharedStorage.coverArtCacheDirectory,
           FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    init(
        dominantColorExtractor: DominantColorExtractor,
        modelContainer: ModelContainer,
        artworkCache: ArtworkImageCache,
        coversDirectory: URL,
        serverState: ServerState,
        storage: UserDefaults? = nil
    ) {
        self.dominantColorExtractor = dominantColorExtractor
        self.modelContainer = modelContainer
        self.artworkCache = artworkCache
        self.coversDirectory = coversDirectory
        self.serverState = serverState
        self.storageOverride = storage
    }

    private func readShared<Value>(_ body: (UserDefaults) -> Value) -> Value {
        if let storageOverride { return body(storageOverride) }
        return SharedStorage.read(body)
    }

    private func writeShared(_ body: @escaping (UserDefaults) -> Void) {
        if let storageOverride { body(storageOverride) }
        else { SharedStorage.write(body) }
    }

    private func prepareAccount() async -> ServerRequestIdentity? {
        guard let identity = await MainActor.run(body: {
            serverState.activeServer.flatMap { try? serverState.requestIdentity(for: $0.id) }
        }) else { return nil }
        if accountIdentity != identity {
            let savedServer = readShared { $0.string(forKey: "cassette.widget.server") }
            if savedServer != identity.serverID.uuidString {
                try? clearForLogout()
                writeShared { $0.set(identity.serverID.uuidString, forKey: "cassette.widget.server") }
            }
            accountIdentity = identity
        }
        return identity
    }

    private func isCurrent(_ identity: ServerRequestIdentity) async -> Bool {
        await MainActor.run { serverState.requestIsCurrent(identity) }
    }

    // MARK: - Recently played + now playing

    func onTrackStarted(_ song: DisplayableSong, isPlaying: Bool = true, publication: PlaybackPublication? = nil) async {
        guard let identity = await prepareAccount(), publication?.isCurrent != false else { return }
        let publishState = acceptPlaybackPublication(publication)
        let coverArtId = song.coverArtId ?? song.id
        let info = SharedTrackInfo(
            id: song.id,
            title: song.title,
            artist: song.artist ?? "",
            albumID: song.albumId,
            coverArtFilename: DownloadService.coverStorageName(for: coverArtId, serverId: identity.serverID) + ".jpg"
        )

        // Widget timeline reads `nowPlayingState` — must update here (not only on pause/resume).
        let nowPlaying = SharedNowPlayingState(track: info, isPlaying: isPlaying, lastUpdated: Date())
        if publishState, let encoded = try? JSONEncoder().encode(nowPlaying) {
            writeShared { defaults in
                if let publication { publication.commit { defaults.set(encoded, forKey: SharedStorageKey.nowPlayingState.rawValue) } }
                else { defaults.set(encoded, forKey: SharedStorageKey.nowPlayingState.rawValue) }
            }
        }

        var items: [SharedTrackInfo] = readShared { defaults in
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
            writeShared { $0.set(encoded, forKey: SharedStorageKey.recentlyPlayedItems.rawValue) }
        }

        try? await bridgeCoverArt(coverArtId: coverArtId, allowNetwork: false)
        await syncDominantColors(forCoverArtIds: [coverArtId])
        // Always refresh Now Playing after a track change (bypass the 2s all-timelines throttle).
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetKind.nowPlaying)
        lastReloadDate = Date()
        Logger.widget.debug("onTrackStarted: updated now playing + recently played (\(items.count) items)")
    }

    // MARK: - Now playing state

    func onPlayStateChanged(isPlaying: Bool, currentSong: DisplayableSong?, publication: PlaybackPublication? = nil) async {
        guard let identity = await prepareAccount(), acceptPlaybackPublication(publication) else { return }
        // Persist every final value; only timeline reloads may be throttled.

        let track: SharedTrackInfo? = currentSong.map { song in
            let coverArtId = song.coverArtId ?? song.id
            return SharedTrackInfo(
                id: song.id,
                title: song.title,
                artist: song.artist ?? "",
                albumID: song.albumId,
                coverArtFilename: DownloadService.coverStorageName(for: coverArtId, serverId: identity.serverID) + ".jpg"
            )
        }
        let nowPlaying = SharedNowPlayingState(track: track, isPlaying: isPlaying, lastUpdated: Date())
        if let encoded = try? JSONEncoder().encode(nowPlaying) {
            writeShared { defaults in
                if let publication { publication.commit { defaults.set(encoded, forKey: SharedStorageKey.nowPlayingState.rawValue) } }
                else { defaults.set(encoded, forKey: SharedStorageKey.nowPlayingState.rawValue) }
            }
        }
        requestNowPlayingReload()
        Logger.widget.debug("onPlayStateChanged: isPlaying=\(isPlaying)")
    }

    // MARK: - Pinned items

    func syncPinned() async {
        guard let identity = await prepareAccount() else { return }
        let sid = identity.serverID
        let (shared, coverArtIds): ([SharedPinnedItem], [String]) = {
        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<PinnedItem>(predicate: #Predicate { $0.serverId == sid }, sortBy: [SortDescriptor(\PinnedItem.sortOrder)])
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
                coverArtFilename: item.coverArtId.map { DownloadService.coverStorageName(for: $0, serverId: sid) + ".jpg" }
            )
        }

        return (shared, dbItems.compactMap(\.coverArtId))
        }()
        guard await isCurrent(identity) else { return }
        if let encoded = try? JSONEncoder().encode(shared) {
            writeShared { $0.set(encoded, forKey: SharedStorageKey.pinnedItems.rawValue) }
        }

        for id in coverArtIds {
            guard await isCurrent(identity) else { return }
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
        guard let identity = await prepareAccount() else { return }
        let generation = accountGeneration
        let allCached = await dominantColorExtractor.cachedColors()
        guard await isCurrent(identity), generation == accountGeneration else { return }
        let filtered = allCached.filter {
            ids.contains($0.key) || ids.contains(DownloadService.coverStorageName(for: $0.key, serverId: identity.serverID))
        }
        guard !filtered.isEmpty else { return }
        // Merge into existing App Group dictionary — replacing wiped other covers' colors.
        writeShared { defaults in
            var merged = defaults.dictionary(forKey: SharedStorageKey.dominantColors.rawValue) as? [String: Int] ?? [:]
            for (key, value) in filtered {
                merged[DownloadService.coverStorageName(for: key, serverId: identity.serverID)] = value
            }
            defaults.set(merged, forKey: SharedStorageKey.dominantColors.rawValue)
        }
        Logger.widget.debug("syncDominantColors: wrote \(filtered.count) colors to shared defaults")
    }

    // MARK: - Cover art bridge

    /// Copies a cover from the app's local cache into the App Group shared container
    /// as a 600×600 JPG at 80% quality. Idempotent — no-op if the file already exists.
    func bridgeCoverArt(coverArtId: String, allowNetwork: Bool = true) async throws {
        guard let identity = await prepareAccount() else { return }
        let generation = accountGeneration
        guard let sharedDir = SharedStorage.coverArtCacheDirectory else {
            throw WidgetSyncError.sharedContainerUnavailable
        }
        try SharedStorage.ensureDirectoriesExist()

        let storageID = DownloadService.coverStorageName(for: coverArtId, serverId: identity.serverID)
        let sharedURL = sharedDir.appendingPathComponent(storageID + ".jpg")
        let originalPath = coversDirectory.appendingPathComponent(DownloadService.coverStorageName(for: OriginalArtwork.storageID(coverArtId), serverId: identity.serverID)).path
        let hasOriginal = FileManager.default.fileExists(atPath: originalPath)
        let needsOriginalUpgrade = hasOriginal && !bridgedOriginals.contains(storageID)
        let needsBridge = !FileManager.default.fileExists(atPath: sharedURL.path) || needsOriginalUpgrade
        let sameAsLast = lastBridgedCoverArtId == storageID

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
                guard await isCurrent(identity), generation == accountGeneration else { return }
                try jpgData.write(to: sharedURL, options: .atomic)
                if hasOriginal { bridgedOriginals.insert(storageID) }
                Logger.widget.debug("bridgeCoverArt: bridged \(coverArtId, privacy: .public) (\(jpgData.count) bytes)")
            }
        }

        // Color extract off the main actor — MainActor only stores the packed result.
        let packed = await Task.detached(priority: .utility) {
            DominantColorExtractor.packedAverageColor(from: image)
        }.value
        guard await isCurrent(identity), generation == accountGeneration else { return }
        _ = await MainActor.run {
            guard serverState.requestIsCurrent(identity) else { return }
            _ = dominantColorExtractor.storeColor(packed: packed, for: coverArtId)
        }
        lastBridgedCoverArtId = storageID
    }

    private func acceptPlaybackPublication(_ publication: PlaybackPublication?) -> Bool {
        guard let publication else { return true }
        guard publication.isCurrent, publication.sequence >= lastPlaybackSequence else { return false }
        lastPlaybackSequence = publication.sequence
        return true
    }

    private func requestNowPlayingReload() {
        let remaining = max(0, 0.8 - Date().timeIntervalSince(lastReloadDate ?? .distantPast))
        if remaining == 0 {
            trailingReloadTask?.cancel()
            trailingReloadTask = nil
            lastReloadDate = Date()
            if storageOverride == nil {
                writeShared { _ in WidgetCenter.shared.reloadTimelines(ofKind: WidgetKind.nowPlaying) }
            }
        } else if trailingReloadTask == nil {
            trailingReloadTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
                guard let self else { return }
                await self.finishTrailingReload()
            }
        }
    }

    private func finishTrailingReload() {
        trailingReloadTask = nil
        requestNowPlayingReload()
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
