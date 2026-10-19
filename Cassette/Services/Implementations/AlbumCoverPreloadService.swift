// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import ImageIO
import SwiftSonic
import OSLog
#if os(iOS)
import UIKit
#endif

/// UI-observable progress for the full-library album cover download.
@MainActor
@Observable
final class AlbumCoverPreloadState {
    /// True while a download pass is running.
    var isDownloading = false
    /// Inventory discovery precedes a meaningful percentage; show an indeterminate loader.
    var isResolvingInventory = false
    var isAnalyzingColors = false
    var colorsCompleted = 0
    var colorsTotal = 0
    /// Covers this pass still has to fetch; retained for work scheduling and diagnostics.
    var total = 0
    /// Number of covers already fetched (success or failure) in the current pass.
    var completed = 0
    /// Covers a previous pass had already written, so this pass had nothing to fetch for them.
    var alreadyPrepared = 0
    var failed = 0
    /// True after the requested preparation pass has finished.
    var isComplete = false
    var errorMessage: String?
    var verifiedUniqueCount: Int?
    /// Disk-backed progress across passes, including files saved before app termination.
    var availableCompleted: Int { isComplete ? (verifiedUniqueCount ?? alreadyPrepared + max(0, completed - failed)) : alreadyPrepared + max(0, completed - failed) }
    var libraryTotal: Int { isComplete ? (verifiedUniqueCount ?? alreadyPrepared + total) : alreadyPrepared + total }
    var fraction: Double {
        guard libraryTotal > 0 else { return isComplete ? 1 : 0 }
        return min(1, max(0, Double(availableCompleted) / Double(libraryTotal)))
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
    private var inventoryServerID: UUID?
    private var downloadTask: Task<Void, Never>?
    private var activeCoverArtId: String?
    #if os(iOS)
    private var submissionTask: UIBackgroundTaskIdentifier = .invalid

    private func finishBackgroundSubmission() {
        guard submissionTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(submissionTask)
        submissionTask = .invalid
    }
    #endif
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
        // A persisted pass is not proof that its files survived eviction or deletion.
        state.isComplete = false
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
            if !state.isResolvingInventory, reported != state.availableCompleted {
                reported = state.availableCompleted
                onProgress?(state.availableCompleted, state.libraryTotal, activeCoverArtId)
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        if !Task.isCancelled { onProgress?(state.availableCompleted, state.libraryTotal, activeCoverArtId) }
    }

    private func startDownloadPassIfNeeded() {
        guard !activePass, !isResettingAccount else { return }
        guard artworkImageCache.allowsNetworkDownloads, serverState?.isCellularConnection != true else {
            state.errorMessage = serverState?.isOnline == false
                ? URLError(.notConnectedToInternet).localizedDescription
                : String(localized: "Connect to Wi-Fi to download artwork.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
            return
        }
        beginPass()
        downloadTask = Task { [weak self] in
            guard let self else { return }
            await self.performDownloadPass()
            self.downloadTask = nil
        }
    }

    private func performDownloadPass() async {
        defer { endPass() }
        await restoreCompletedInventory()
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
            reportPreparation?(.init(phase: .failed, coversCompleted: state.availableCompleted, coversTotal: state.libraryTotal))
        }
    }

    /// Fetches the latest album list and re-downloads any cover whose `coverArtId` changed
    /// since the last known snapshot. Cheap when nothing changed (one `allAlbums()` call).
    /// Coalesced with a single-slot task so a barrage of `.task` triggers cannot overlap.
    func reconcileChangedCovers() {
        guard BulkArtworkPreference.isEnabled else { return }
        guard artworkImageCache.allowsNetworkDownloads, serverState?.isCellularConnection != true else { return }
        guard reconcileTask == nil, !isResettingAccount else { return }
        reconcileTask = Task { [weak self] in
            defer { self?.reconcileTask = nil }
            guard let self else { return }
            guard !self.activePass, !Task.isCancelled else { return }
            self.beginPass()
            defer { self.endPass() }
            await self.restoreCompletedInventory()
            guard let albumsList = try? await self.libraryService.allAlbums() else { return }
            guard !Task.isCancelled else { return }
            let songCovers: [String: String]
            do { songCovers = try await self.songCoverProvider?() ?? [:] }
            catch { return }
            guard !Task.isCancelled else { return }
            let current = Self.snapshot(from: albumsList).merging(songCovers) { _, song in song }
            // IDs only detect metadata changes. Files may have been evicted, deleted or
            // damaged without any ID changing. Reconcile the complete disk inventory;
            // downloadCovers still schedules only missing/invalid originals.
            let succeeded = await self.runCoverPass(albums: albumsList, additionalCoverIDs: Array(songCovers.values))
            if succeeded { self.snapshotStore.snapshot = current }
            self.state.isComplete = succeeded
            self.snapshotStore.finishedFullPass = succeeded
        }
    }

    /// Restore offline completion before fetching metadata or showing a new download prompt.
    func restoreCompletedInventory() async {
        guard !isResettingAccount, let directory = coversDirectory,
              let serverID = serverState?.activeServer?.id else { return }
        if inventoryServerID != serverID {
            state.isComplete = false
            state.verifiedUniqueCount = nil
            inventoryServerID = serverID
        }
        guard !state.isDownloading, !state.isAnalyzingColors else { return }
        let record = await Task.detached(priority: .utility) {
            ArtworkCompletionInventory.load(directory: directory, serverID: serverID)
        }.value
        guard !Task.isCancelled, !isResettingAccount, !state.isDownloading, !state.isAnalyzingColors,
              serverState?.activeServer?.id == serverID else { return }
        guard let record else { return }
        state.alreadyPrepared = record.files.count
        state.total = 0
        state.completed = 0
        state.failed = 0
        state.verifiedUniqueCount = record.uniqueCount
        state.isComplete = true
        state.isDownloading = false
        state.errorMessage = nil
        // Finish the shared progress/Live Activity as well as the local cover state.
        reportPreparation?(.init(phase: .complete, coversCompleted: record.uniqueCount, coversTotal: record.uniqueCount))
    }

    /// Clears the stored snapshot and completion flag (called when the artwork cache is wiped).
    func resetBookkeeping() {
        snapshotStore.clear()
        if let directory = coversDirectory, let serverID = serverState?.activeServer?.id {
            ArtworkCompletionInventory.clear(directory: directory, serverID: serverID)
        }
        state.verifiedUniqueCount = nil
        state.isAnalyzingColors = false
        state.colorsCompleted = 0
        state.colorsTotal = 0
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

    func resumeArtworkAfterNetworkChange() {
        guard artworkImageCache.allowsNetworkDownloads, serverState?.isCellularConnection != true else { return }
        let wifiMessage = String(localized: "Connect to Wi-Fi to download artwork.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        if state.errorMessage == wifiMessage || state.errorMessage == URLError(.notConnectedToInternet).localizedDescription {
            state.errorMessage = nil
        }
        reconcileChangedCovers()
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
        #if os(iOS)
        // This short execution window is only for discovering/submitting work. Downloads
        // themselves belong to URLSession and do not require the application to keep running.
        submissionTask = UIApplication.shared.beginBackgroundTask(withName: "Queue album covers") { [weak self] in
            Task { @MainActor in self?.finishBackgroundSubmission() }
        }
        #endif
        activePass = true
        state.isResolvingInventory = true
        state.errorMessage = nil
        activeCoverArtId = nil
        requestBackgroundContinuation?()
    }

    private func endPass() {
        #if os(iOS)
        finishBackgroundSubmission()
        #endif
        activePass = false
        state.isDownloading = false
        state.isAnalyzingColors = false
        state.isResolvingInventory = false
        if !state.isComplete, state.total > 0, !isResettingAccount { requestBackgroundContinuation?() }
    }

    static func coverIDs(for albums: [AlbumID3], songCoverIDs: [String] = []) -> [String] {
        ArtworkIdentity.distinct(albums.compactMap(\.coverArt) + songCoverIDs)
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
        state.isComplete = succeeded
        if succeeded { state.isDownloading = false }
        reportPreparation?(LibraryPreparationProgress(
            phase: Task.isCancelled ? .idle : succeeded ? .complete : .failed,
            coversCompleted: state.availableCompleted,
            coversTotal: state.libraryTotal
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
        var seenThemeIDs = Set<String>()
        let themeIDs = (albums.compactMap(\.coverArt) + additionalCoverIDs).compactMap { value -> String? in
            let id = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return !id.isEmpty && seenThemeIDs.insert(id).inserted ? id : nil
        }
        // Resuming must not fetch what a previous pass already wrote: the hero file on disk is that
        // pass's record of progress. So only the missing covers are queued — and only they are
        // counted, so the progress shown is the work that is actually left. The per-cover check in
        // `downloadOriginalAndCacheAsHero` stays as the authoritative gate; this is the cheap probe
        // that avoids it.
        let directory = coversDirectory
        let serverID = serverState?.activeServer?.id
        let prepared = await Task.detached(priority: .utility) {
            guard let directory else { return Set<String>() }
            if let serverID, let record = ArtworkCompletionInventory.load(directory: directory, serverID: serverID) {
                let prepared = Set(record.files.map(\.name))
                let expected = Set(allIDs.map { DownloadService.coverStorageName(for: OriginalArtwork.storageID($0), serverId: serverID) })
                if expected.isSubset(of: prepared) { return prepared }
            }
            try? ArtworkContentStore.reconcile(directory: directory)
            var names = Set((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            // Promote old entity-keyed files before filtering the work list. A cache-key
            // improvement must not force the listener to download prepared images again.
            if let serverID {
                for id in albums.compactMap(\.coverArt) + additionalCoverIDs {
                    let original = OriginalArtwork.storageID(id)
                    let old = DownloadService.legacyCoverStorageName(for: original, serverId: serverID)
                    let shared = DownloadService.coverStorageName(for: original, serverId: serverID)
                    if names.contains(old), !names.contains(shared) {
                        do {
                            try FileManager.default.moveItem(at: directory.appendingPathComponent(old), to: directory.appendingPathComponent(shared))
                            names.insert(shared)
                        } catch { }
                    }
                }
            }
            return Set(names.filter { name in
                guard name.hasSuffix("@original-v1") else { return false }
                return CassetteBackgroundDownloads.isValidArtwork(at: directory.appendingPathComponent(name))
            })
        }.value
        guard !Task.isCancelled else { return false }
        let ids = allIDs.filter { id in
            let original = OriginalArtwork.storageID(id)
            let filename = serverID.map { DownloadService.coverStorageName(for: original, serverId: $0) } ?? original
            return !prepared.contains(filename)
        }
        state.total = ids.count
        state.completed = 0
        state.failed = 0
        state.alreadyPrepared = allIDs.count - ids.count
        state.isResolvingInventory = false
        if state.alreadyPrepared > 0 {
            Logger.artworkCache.notice(
                "[COVER-PRELOAD] \(self.state.alreadyPrepared, privacy: .public) covers already prepared — \(ids.count, privacy: .public) to download"
            )
        }
        // Announced only when there is work: a resume that finds every cover on disk must not start a
        // Live Activity or take over the screen for a no-op.
        if !ids.isEmpty {
            state.isDownloading = true
            state.isComplete = false
            state.verifiedUniqueCount = nil
            snapshotStore.finishedFullPass = false
            reportPreparation?(LibraryPreparationProgress(phase: .covers, coversCompleted: state.availableCompleted, coversTotal: state.libraryTotal))
        }
        #if os(iOS)
        if let coversDirectory {
            while playerState?.playbackState.isAwaitingAudio == true, !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { break }
            }
            await artworkImageCache.enqueueBackgroundOriginals(coverIDs: ids, directory: coversDirectory)
        }
        finishBackgroundSubmission()
        #endif
        let inventoryMonitor = Task { @MainActor [weak self] in
            var verified = Set<String>()
            while !Task.isCancelled {
                guard let self, let directory = coversDirectory else { return }
                let outstanding = ids.filter { !verified.contains($0) }
                let newlyPrepared = await Task.detached(priority: .utility) {
                    outstanding.filter { id in
                        let original = OriginalArtwork.storageID(id)
                        let name = serverID.map { DownloadService.coverStorageName(for: original, serverId: $0) } ?? original
                        return CassetteBackgroundDownloads.isValidArtwork(at: directory.appendingPathComponent(name))
                    }
                }.value
                guard !Task.isCancelled else { return }
                verified.formUnion(newlyPrepared)
                if verified.count > self.state.completed {
                    self.state.completed = verified.count
                    onProgress?(self.state.availableCompleted, self.state.libraryTotal, nil)
                    self.reportPreparation?(.init(phase: .covers, coversCompleted: self.state.availableCompleted,
                                                  coversTotal: self.state.libraryTotal))
                }
                if verified.count == ids.count { return }
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
        defer { inventoryMonitor.cancel() }
        // Observe progress with bounded workers. The iOS daemon already owns the inventory.
        await withTaskGroup(of: (String, Bool).self) { group in
            var next = 0
            var running = 0
            var observedCompletions = 0
            func enqueue(_ id: String) {
                group.addTask { @MainActor [artworkImageCache, coversDirectory] in
                    guard !Task.isCancelled else { return (id, false) }
                    let downloaded = await artworkImageCache.downloadOriginalAndCacheAsHero(
                        coverArtId: id, cacheHero: false, preparationDirectory: coversDirectory
                    )
                    guard downloaded, !Task.isCancelled else { return (id, false) }
                    return (id, true)
                }
            }
            while next < ids.count || running > 0 {
                guard !Task.isCancelled, !isResettingAccount,
                      artworkImageCache.allowsNetworkDownloads, serverState?.isCellularConnection != true else {
                    group.cancelAll()
                    break
                }
                let limit = PreparationDownloadPolicy.concurrency(
                    budget: CassettePerformance.budget,
                    isLimited: serverState?.isLimitedNetwork == true,
                    isPlaying: playerState?.playbackState == .playing
                )
                // Bulk artwork yields even on unmetered Wi-Fi: path cost says nothing
                // about a home server's uplink. Let existing transfers drain, then wait.
                let audioHasPriority = playerState?.playbackState.isAwaitingAudio == true
                while !audioHasPriority, next < ids.count, running < limit {
                    enqueue(ids[next])
                    next += 1
                    running += 1
                }
                if running == 0, audioHasPriority {
                    do { try await Task.sleep(for: .milliseconds(250)) } catch { break }
                    continue
                }
                guard let (id, success) = await group.next() else { break }
                running -= 1
                activeCoverArtId = id
                observedCompletions += 1
                state.completed = max(state.completed, observedCompletions)
                if !success { state.failed += 1 }
                onProgress?(state.availableCompleted, state.libraryTotal, id)
                reportPreparation?(.init(phase: .covers, coversCompleted: state.availableCompleted,
                                         coversTotal: state.libraryTotal, activeCoverArtId: id))
            }
        }
        guard !Task.isCancelled, !isResettingAccount,
              artworkImageCache.allowsNetworkDownloads, serverState?.isCellularConnection != true else { return false }
        // Disk is authoritative even if an observer saw a transient error while a daemon
        // retry subsequently installed the image. Never carry that stale failure into relaunch.
        if let directory = coversDirectory {
            let validCount = await Task.detached(priority: .utility) {
                ids.filter { id in
                    let original = OriginalArtwork.storageID(id)
                    let name = serverID.map { DownloadService.coverStorageName(for: original, serverId: $0) } ?? original
                    return CassetteBackgroundDownloads.isValidArtwork(at: directory.appendingPathComponent(name))
                }.count
            }.value
            guard !Task.isCancelled, !isResettingAccount else { return false }
            state.failed = ids.count - validCount
        }
        Logger.artworkCache.info("[COVER-PRELOAD] completed \(self.state.completed, privacy: .public)/\(self.state.total, privacy: .public) album covers")
        if state.failed > 0 {
            state.errorMessage = String(localized: "Some album covers could not be downloaded. Please try again.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        }
        // Prepare missing palettes even for originals fetched on an earlier launch.
        // One utility analysis at a time; resource limits pace work rather than skip it.
        guard state.failed == 0 else { return false }
        state.isDownloading = false
        state.isAnalyzingColors = true
        state.colorsCompleted = 0
        state.colorsTotal = themeIDs.count
        let identities = await Task.detached(priority: .utility) {
            Dictionary(themeIDs.map { id in
                let identity = directory.flatMap { directory in
                    let name = serverID.map { DownloadService.coverStorageName(for: OriginalArtwork.storageID(id), serverId: $0) }
                        ?? OriginalArtwork.storageID(id)
                    return ArtworkContentStore.fileIdentity(directory.appendingPathComponent(name))
                } ?? ArtworkIdentity.key(id)
                return (id, identity)
            }, uniquingKeysWith: { first, _ in first })
        }.value
        var paletteSources: [String: String] = [:]
        var colorFailures = 0
        for id in themeIDs {
            guard !Task.isCancelled, !isResettingAccount, serverState?.activeServer?.id == serverID else { return false }
            let identity = identities[id] ?? ArtworkIdentity.key(id)
            if let source = paletteSources[identity], let palette = ColorCache.palette(for: source) {
                ColorCache.store(palette, for: id)
                dominantColorExtractor?.storePreparedBackground(palette.packedBackground, for: id)
            } else if await Self.prepareTheme(for: id, artworkImageCache: artworkImageCache,
                                              dominantColorExtractor: dominantColorExtractor,
                                              originalURL: directory.map { directory in
                                                  let name = serverID.map { DownloadService.coverStorageName(for: OriginalArtwork.storageID(id), serverId: $0) } ?? OriginalArtwork.storageID(id)
                                                  return directory.appendingPathComponent(name)
                                              }) {
                paletteSources[identity] = id
            } else {
                colorFailures += 1
            }
            state.colorsCompleted += 1
        }
        state.isAnalyzingColors = false
        Logger.artworkCache.info("[COVER-PRELOAD] palettes prepared \(self.state.colorsCompleted - colorFailures, privacy: .public)/\(self.state.colorsTotal, privacy: .public); failed \(colorFailures, privacy: .public)")
        guard colorFailures == 0 else {
            state.errorMessage = String(localized: "Some cover colors could not be prepared. Please try again.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
            return false
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
        await ColorCache.persistPreparedPalettes()
        let succeeded = !Task.isCancelled && state.failed == 0 && state.completed == state.total
        if succeeded, let directory = coversDirectory, let serverID {
            let inventory = await Task.detached(priority: .utility) {
                try? ArtworkCompletionInventory.save(ids: allIDs, directory: directory, serverID: serverID)
            }.value
            guard !Task.isCancelled, !isResettingAccount, serverState?.activeServer?.id == serverID else { return false }
            guard let inventory else {
                state.errorMessage = String(localized: "Could not save cover preparation progress. Check available storage and try again.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
                Logger.artworkCache.error("[COVER-PRELOAD] could not persist the validated completion inventory")
                return false
            }
            state.verifiedUniqueCount = inventory.uniqueCount
        }
        return succeeded
    }

    static func prepareTheme(
        for coverArtId: String,
        artworkImageCache: ArtworkImageCache,
        dominantColorExtractor: DominantColorExtractor?,
        originalURL: URL? = nil
    ) async -> Bool {
        let palette: ArtworkPalette
        if let cached = ColorCache.palette(for: coverArtId) {
            palette = cached
        } else {
            let image: PlatformImage?
            if originalURL == nil {
                image = await artworkImageCache.load(coverArtId: coverArtId, tier: .thumb, allowNetwork: false)
            } else { image = nil }
            guard !Task.isCancelled else { return false }
            let generated = await Task.detached(priority: .utility) { () -> ArtworkPalette? in
                if let image { return AlbumColorAnalyzer.generateArtworkPalette(from: image) }
                guard let originalURL,
                      let source = CGImageSourceCreateWithURL(originalURL as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                      let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: 240,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceShouldCacheImmediately: true
                      ] as CFDictionary) else { return nil }
                return AlbumColorAnalyzer.generateArtworkPalette(from: thumbnail)
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
