// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import SwiftSonic
import OSLog

/// UI-observable progress for the full-library album cover download.
@MainActor
@Observable
final class AlbumCoverPreloadState {
    /// True while a download pass is running.
    var isDownloading = false
    /// Covers this pass still has to fetch. A resumed pass counts only what is missing, so the
    /// progress shown is the work actually left rather than the size of the library.
    var total = 0
    /// Number of covers already fetched (success or failure) in the current pass.
    var completed = 0
    /// Covers a previous pass had already written, so this pass had nothing to fetch for them.
    var alreadyPrepared = 0
    var failed = 0
    /// True after cover files are prepared; constrained devices resolve palettes on demand.
    var isComplete = false
    var errorMessage: String?
    /// Fraction 0…1 of the current pass.
    var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(completed) / Double(total)))
    }
}

/// Downloads full-resolution (1200 px hero tier) cover art for every album in the library so
/// the app renders artwork at its highest quality without per-view network round-trips.
///
/// Each cover is fetched without a resize parameter through ``ArtworkImageCache`` and persisted
/// verbatim to `{coverArtId}@original-v1`. Bounded UI decodes resolve that original before derivatives.
///
/// Change detection stores a snapshot of `albumId → coverArtId`; on launch and on album-page
/// access the latest library is reconciled and any album whose cover id changed is re-downloaded.
@MainActor
@Observable
final class AlbumCoverPreloadService {
    let state = AlbumCoverPreloadState()

    private let libraryService: any LibraryServiceProtocol
    private let songCoverProvider: (@MainActor () async throws -> [String: String])?
    private let artworkImageCache: ArtworkImageCache
    /// Optional so lightweight/offline tests can exercise cover download bookkeeping
    /// without constructing another main-actor UI color cache.
    private let dominantColorExtractor: DominantColorExtractor?
    /// Optional so lightweight/offline tests can exercise cover download bookkeeping without a
    /// player. When present, playback on a limited link reduces download concurrency.
    private let playerState: PlayerState?
    private let serverState: ServerState?
    private let snapshotStore = AlbumCoverSnapshotStore()
    private var reconcileTask: Task<Void, Never>?
    /// Single-flight guard: only one cover download pass may run at a time so `state.total`
    /// / `state.completed` cannot be overwritten mid-pass by a concurrent caller (the boot
    /// reconcile and the onboarding/manual download can fire together).
    private var activePass = false
    private var downloadTask: Task<Void, Never>?
    private var activeCoverArtId: String?
    var requestBackgroundContinuation: (@MainActor () -> Void)?
    /// The user left the preparation screen; transfers continue independently.
    private(set) var isDeferred = false

    func deferRemainingDownloads() {
        isDeferred = true
        requestBackgroundContinuation?()
        startDownloadPassIfNeeded()
    }
    /// Reports the cover stage into the shared progress model, which owns the Live Activity update,
    /// the localized phase title and the App Group artwork bridge.
    ///
    /// Injected because the full cover download is the one pass with callers outside
    /// `LibraryPreparationService`: onboarding's first download, the launch-time resume, and the
    /// manual "download all covers" action in storage settings all run through it. Reporting here —
    /// rather than at each call site — is what keeps every one of them on the same screen and the
    /// same Live Activity.
    var reportPreparation: (@MainActor (LibraryPreparationProgress) -> Void)?

    private var isResettingAccount = false

    init(
        libraryService: any LibraryServiceProtocol,
        artworkImageCache: ArtworkImageCache,
        dominantColorExtractor: DominantColorExtractor? = nil,
        playerState: PlayerState? = nil,
        serverState: ServerState? = nil,
        coversDirectory: URL? = nil,
        songCoverProvider: (@MainActor () async throws -> [String: String])? = nil
    ) {
        self.libraryService = libraryService
        self.songCoverProvider = songCoverProvider
        self.artworkImageCache = artworkImageCache
        self.dominantColorExtractor = dominantColorExtractor
        self.playerState = playerState
        self.serverState = serverState
        self.coversDirectory = coversDirectory
        state.isComplete = snapshotStore.finishedFullPass
    }

    /// Directory the hero files are written to (see `DownloadService.persistCover`). Probed directly
    /// to learn what a previous pass already fetched — the authoritative check,
    /// `ArtworkImageCache.downloadOriginalAndCacheAsHero`, resolves media-identity aliases through
    /// CoreData on every call, which is far too heavy to run once per album.
    private let coversDirectory: URL?

    /// Downloads every distinct album cover at hero resolution. Safe to call repeatedly — a
    /// cover already on disk resolves as a RAM/disk hit and does no network work.
    ///
    /// Callers observe the owned pass; leaving a screen cancels only that caller's wait.
    /// Per-cover artwork updates are delivered directly through `reportPreparation`.
    func downloadAllCovers(resumeDeferred: Bool = true, onProgress: (@MainActor (Int, Int, String?) -> Void)? = nil) async {
        guard !isResettingAccount, !Task.isCancelled else { return }
        startDownloadPassIfNeeded()
        var reported = -1
        while activePass, !Task.isCancelled {
            if reported != state.completed {
                reported = state.completed
                onProgress?(state.completed, state.total, activeCoverArtId)
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        if !Task.isCancelled { onProgress?(state.completed, state.total, activeCoverArtId) }
    }

    private func startDownloadPassIfNeeded() {
        guard !activePass, !isResettingAccount else { return }
        beginPass()
        downloadTask = Task { [weak self] in
            guard let self else { return }
            await self.performDownloadPass()
            self.downloadTask = nil
        }
    }

    private func performDownloadPass() async {
        state.isComplete = false
        snapshotStore.finishedFullPass = false
        defer { endPass() }
        do {
            let albums = try await libraryService.allAlbums()
            let songCovers = try await songCoverProvider?() ?? [:]
            try Task.checkCancellation()
            let succeeded = await runCoverPass(albums: albums, additionalCoverIDs: Array(songCovers.values))
            state.isComplete = succeeded
            snapshotStore.finishedFullPass = succeeded
            if succeeded { snapshotStore.snapshot = Self.snapshot(from: albums).merging(songCovers) { _, song in song } }
        } catch {
            guard !Task.isCancelled else { return }
            state.errorMessage = error.localizedDescription
            reportPreparation?(.init(phase: .failed, coversCompleted: state.completed, coversTotal: state.total))
        }
    }

    /// Fetches the latest album list and re-downloads any cover whose `coverArtId` changed
    /// since the last known snapshot. Cheap when nothing changed (one `allAlbums()` call).
    /// Coalesced with a single-slot task so a barrage of `.task` triggers cannot overlap.
    func reconcileChangedCovers() {
        guard BulkArtworkPreference.isEnabled else { return }
        guard reconcileTask == nil, !isResettingAccount else { return }
        reconcileTask = Task { [weak self] in
            defer { self?.reconcileTask = nil }
            guard let self else { return }
            guard !self.activePass, !Task.isCancelled else { return }
            self.beginPass()
            defer { self.endPass() }
            guard let albumsList = try? await self.libraryService.allAlbums() else { return }
            guard !Task.isCancelled else { return }
            let songCovers: [String: String]
            do { songCovers = try await self.songCoverProvider?() ?? [:] }
            catch { return }
            guard !Task.isCancelled else { return }
            let current = Self.snapshot(from: albumsList).merging(songCovers) { _, song in song }
            let previous = self.snapshotStore.snapshot
            if previous == nil || !self.snapshotStore.finishedFullPass {
                // First launch with a server: record the baseline, then do a full download pass.
                let succeeded = await self.runCoverPass(albums: albumsList, additionalCoverIDs: Array(songCovers.values))
                if succeeded { self.snapshotStore.snapshot = current }
                self.state.isComplete = succeeded
                self.snapshotStore.finishedFullPass = succeeded
                return
            }
            let changed = Set(current.keys.filter { previous?[$0] != current[$0] })
            guard !changed.isEmpty else { return }
            self.state.isComplete = false
            self.snapshotStore.finishedFullPass = false
            let staleAlbums = albumsList.filter { changed.contains($0.id) }
            let changedSongCovers = changed.compactMap { songCovers[$0] }
            if await self.runCoverPass(albums: staleAlbums, additionalCoverIDs: changedSongCovers) {
                self.snapshotStore.snapshot = current
                self.state.isComplete = true
                self.snapshotStore.finishedFullPass = true
            }
        }
    }

    /// Clears the stored snapshot and completion flag (called when the artwork cache is wiped).
    func resetBookkeeping() {
        snapshotStore.clear()
        state.isComplete = false
        state.total = 0
        state.completed = 0
        state.alreadyPrepared = 0
        state.failed = 0
    }

    func pauseAutomaticDownloads() {
        downloadTask?.cancel()
        reconcileTask?.cancel()
    }

    /// Album-only fallback for items without track artwork identity.
    func preparedCoverArtId(forAlbumId albumId: String?) -> String? {
        guard let albumId else { return nil }
        return snapshotStore.snapshot?[albumId]
    }

    // MARK: - Private

    /// Drain the current batch before deleting files to prevent late writes.
    func suspendForAccountReset() async throws {
        isResettingAccount = true
        downloadTask?.cancel()
        reconcileTask?.cancel()
        #if os(iOS)
        await CassetteBackgroundDownloads.artwork.cancelAll()
        #endif
        while activePass {
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    func finishAccountReset() {
        resetBookkeeping()
        isResettingAccount = false
        isDeferred = false
    }

    private func beginPass() {
        activePass = true
        state.isDownloading = true
        state.errorMessage = nil
        state.total = 0
        state.completed = 0
        state.failed = 0
        activeCoverArtId = nil
        requestBackgroundContinuation?()
    }

    private func endPass() {
        activePass = false
        state.isDownloading = false
        if !state.isComplete, !isResettingAccount { requestBackgroundContinuation?() }
    }

    static func coverIDs(for albums: [AlbumID3], songCoverIDs: [String] = []) -> [String] {
        var seen = Set<String>()
        return (albums.compactMap(\.coverArt) + songCoverIDs).compactMap { value in
            let cover = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cover.isEmpty, seen.insert(cover).inserted else { return nil }
            return cover
        }
    }

    /// Runs a cover pass with the shared progress reporting wrapped around it, so a pass started by
    /// onboarding, by a launch that found covers missing, or by the change-detection pass is
    /// announced, followed and finished exactly the same way.
    private func runCoverPass(
        albums: [AlbumID3],
        additionalCoverIDs: [String] = [],
        onProgress: (@MainActor (Int, Int, String?) -> Void)? = nil
    ) async -> Bool {
        let succeeded = await downloadCovers(for: albums, additionalCoverIDs: additionalCoverIDs, onProgress: onProgress)
        reportPreparation?(LibraryPreparationProgress(
            phase: Task.isCancelled ? .idle : succeeded ? .complete : .failed,
            coversCompleted: state.completed,
            coversTotal: state.total
        ))
        return succeeded
    }

    private func downloadCovers(
        for albums: [AlbumID3],
        additionalCoverIDs: [String] = [],
        onProgress: (@MainActor (Int, Int, String?) -> Void)? = nil
    ) async -> Bool {
        guard !isResettingAccount, !Task.isCancelled else { return false }
        let allIDs = Self.coverIDs(for: albums, songCoverIDs: additionalCoverIDs)
        let albumCoverIDs = Set(Self.coverIDs(for: albums))
        // Resuming must not fetch what a previous pass already wrote: the hero file on disk is that
        // pass's record of progress. So only the missing covers are queued — and only they are
        // counted, so the progress shown is the work that is actually left. The per-cover check in
        // `downloadOriginalAndCacheAsHero` stays as the authoritative gate; this is the cheap probe
        // that avoids it.
        let directory = coversDirectory
        let prepared = await Task.detached(priority: .utility) {
            guard let directory else { return Set<String>() }
            return Set((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
        }.value
        guard !Task.isCancelled else { return false }
        let ids = allIDs.filter { !prepared.contains(OriginalArtwork.storageID($0)) }
        state.total = ids.count
        state.completed = 0
        state.failed = 0
        state.alreadyPrepared = allIDs.count - ids.count
        if state.alreadyPrepared > 0 {
            Logger.artworkCache.notice(
                "[COVER-PRELOAD] \(self.state.alreadyPrepared, privacy: .public) covers already prepared — \(ids.count, privacy: .public) to download"
            )
        }
        // Announced only when there is work: a resume that finds every cover on disk must not start a
        // Live Activity or take over the screen for a no-op.
        if !ids.isEmpty {
            reportPreparation?(LibraryPreparationProgress(phase: .covers, coversTotal: ids.count))
        }
        // Refill each free slot immediately; one slow image must not stall an entire batch.
        await withTaskGroup(of: (String, Bool).self) { group in
            var next = 0
            var running = 0
            func enqueue(_ id: String) {
                let needsPalette = albumCoverIDs.contains(id)
                group.addTask { @MainActor [artworkImageCache, dominantColorExtractor, coversDirectory] in
                    guard !Task.isCancelled else { return (id, false) }
                    let downloaded = await artworkImageCache.downloadOriginalAndCacheAsHero(
                        coverArtId: id, cacheHero: false, preparationDirectory: coversDirectory
                    )
                    guard downloaded, !Task.isCancelled else { return (id, false) }
                    // Track artwork needs persistence, not thousands of eager palette analyses.
                    // The player resolves a track's colors when that track is actually displayed.
                    guard needsPalette else { return (id, true) }
                    let prepared = await Self.prepareThemeIfBudgetAllows(
                        for: id, artworkImageCache: artworkImageCache,
                        dominantColorExtractor: dominantColorExtractor
                    )
                    return (id, prepared)
                }
            }
            while next < ids.count || running > 0 {
                guard !Task.isCancelled, !isResettingAccount else { group.cancelAll(); break }
                let limit = PreparationDownloadPolicy.concurrency(
                    budget: CassettePerformance.budget,
                    isLimited: serverState?.isLimitedNetwork == true,
                    isPlaying: playerState?.playbackState == .playing
                )
                while next < ids.count, running < limit {
                    enqueue(ids[next])
                    next += 1
                    running += 1
                }
                guard let (id, success) = await group.next() else { break }
                running -= 1
                activeCoverArtId = id
                state.completed += 1
                if !success { state.failed += 1 }
                onProgress?(state.completed, state.total, id)
                reportPreparation?(.init(phase: .covers, coversCompleted: state.completed,
                                         coversTotal: state.total, activeCoverArtId: id))
            }
        }
        guard !Task.isCancelled, !isResettingAccount else { return false }
        Logger.artworkCache.info("[COVER-PRELOAD] completed \(self.state.completed, privacy: .public)/\(self.state.total, privacy: .public) album covers")
        if state.failed > 0 {
            state.errorMessage = String(localized: "Some album covers could not be downloaded. Please try again.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        }
        // Album navigation occasionally knows only the album id. Mirror the prepared
        // cover palette under that stable key so its very first detail frame is themed.
        for album in albums {
            guard let cover = album.coverArt?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let palette = ColorCache.palette(for: cover) else { continue }
            ColorCache.store(palette, for: album.id)
            dominantColorExtractor?.storePreparedBackground(palette.packedBackground, for: album.id)
        }
        // Persist cover-id and album-id lookups before the preparation UI advances.
        dominantColorExtractor?.persistPreparedBackgrounds()
        return !Task.isCancelled && state.failed == 0
    }

    /// Bulk-pass entry point: the k-means palette is the expensive half of preparing a cover and it
    /// is optional, so a constrained device (Low Power Mode, thermal pressure, memory warning,
    /// background) only caches the artwork here and lets the theme resolve on demand when the album
    /// is actually opened. `prepareTheme` itself stays unconditional for direct/on-demand callers.
    private static func prepareThemeIfBudgetAllows(
        for coverArtId: String,
        artworkImageCache: ArtworkImageCache,
        dominantColorExtractor: DominantColorExtractor?
    ) async -> Bool {
        guard CassettePerformance.allowsHeavyColorAnalysis else {
            Logger.artworkCache.debug("[COVER-PRELOAD] palette analysis deferred (device constrained)")
            return true
        }
        return await prepareTheme(
            for: coverArtId,
            artworkImageCache: artworkImageCache,
            dominantColorExtractor: dominantColorExtractor
        )
    }

    static func prepareTheme(
        for coverArtId: String,
        artworkImageCache: ArtworkImageCache,
        dominantColorExtractor: DominantColorExtractor?
    ) async -> Bool {
        let palette: ArtworkPalette
        if let cached = ColorCache.palette(for: coverArtId) {
            palette = cached
        } else {
            // A successful download may be a disk-only hit (or the image may have
            // been evicted from RAM). Resolve that file before preparing its theme.
            guard let image = await artworkImageCache.load(coverArtId: coverArtId, tier: .thumb, allowNetwork: false),
                  !Task.isCancelled else { return false }
            let generated = await Task.detached(priority: .utility) {
                AlbumColorAnalyzer.generateArtworkPalette(from: image)
            }.value
            guard !Task.isCancelled, let generated else { return false }
            palette = generated
            ColorCache.store(palette, for: coverArtId)
        }
        guard !Task.isCancelled else { return false }
        if let dominantColorExtractor {
            dominantColorExtractor.storePreparedBackground(
                palette.packedBackground,
                for: coverArtId
            )
        }
        return ColorCache.palette(for: coverArtId) != nil
    }

    private static func snapshot(from albums: [AlbumID3]) -> [String: String] {
        var result: [String: String] = [:]
        for album in albums {
            if let cover = album.coverArt?.trimmingCharacters(in: .whitespacesAndNewlines), !cover.isEmpty {
                result[album.id] = cover
            }
        }
        return result
    }
}

/// Persists the `albumId → coverArtId` snapshot and the finished-full-pass flag as JSON in
/// Caches. Reference type so it can be held via `let` while its contents mutate.
private final class AlbumCoverSnapshotStore {
    private static let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("app.cassette", isDirectory: true)
    private static let fileURL = directory.appendingPathComponent("album-covers-snapshot.json")
    // Old passes could succeed with missing palettes. Revisit their cached files
    // once after upgrading; existing hero files do not need to be downloaded again.
    private static let finishedKey = "cassette.albumCovers.finishedFullPass.trackArtwork.v3"
    private var cachedSnapshot: [String: String]?
    private var didLoadSnapshot = false

    var finishedFullPass: Bool {
        get { UserDefaults.standard.bool(forKey: Self.finishedKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.finishedKey) }
    }

    var snapshot: [String: String]? {
        get {
            if didLoadSnapshot { return cachedSnapshot }
            didLoadSnapshot = true
            guard let data = try? Data(contentsOf: Self.fileURL) else { return nil }
            cachedSnapshot = try? JSONDecoder().decode([String: String].self, from: data)
            return cachedSnapshot
        }
        set {
            didLoadSnapshot = true
            cachedSnapshot = newValue
            do {
                try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
                if let newValue {
                    try JSONEncoder().encode(newValue).write(to: Self.fileURL, options: .atomic)
                } else {
                    try? FileManager.default.removeItem(at: Self.fileURL)
                }
            } catch {
                Logger.artworkCache.warning("[COVER-PRELOAD] snapshot write failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func clear() {
        didLoadSnapshot = true
        cachedSnapshot = nil
        try? FileManager.default.removeItem(at: Self.fileURL)
        UserDefaults.standard.removeObject(forKey: Self.finishedKey)
    }
}

/// Network transfers need neither foreground animation budget nor full-size image decoding.
nonisolated enum PreparationDownloadPolicy {
    static func concurrency(budget: PerformanceBudget, isLimited: Bool, isPlaying: Bool) -> Int {
        if budget.thermalPressure >= .serious || budget.isMemoryPressured || (isPlaying && isLimited) { return 1 }
        if budget.isLowPowerMode || budget.thermalPressure == .fair || isLimited || isPlaying { return 2 }
        return 4
    }
}

/// Full-library original artwork is optional. Visible covers still load on demand.
nonisolated enum BulkArtworkPreference {
    static let key = "cassette.artwork.autoDownloadFullLibrary"
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: key) }
}
