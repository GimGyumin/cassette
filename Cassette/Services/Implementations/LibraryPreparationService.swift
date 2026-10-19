// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import OSLog
import SwiftSonic

/// Shared phase model: the in-app preparation screen, the Live Activity and this service must all
/// agree on what "indexing" or "covers" means, so the enum lives in `Cassette/Shared`.
typealias Phase = LibraryPreparationPhase

/// Runs the "preparing your library" pass when the server reports that music was added or removed.
///
/// Order matters: the local index is rebuilt first (search and AI context depend on it), then
/// opt-in full-library artwork is reconciled, and finally caches built from the old catalog are
/// dropped. Progress is visible in Account while the rest of the app stays usable.
@MainActor
@Observable
final class LibraryPreparationService {

    private(set) var phase: Phase = .idle
    /// Keep the app usable after the user leaves first-run preparation.
    private(set) var isPresentationDeferred = false

    func deferPresentation() { isPresentationDeferred = true }
    /// Server-reported media-file count that triggered this pass, for the progress copy.
    private(set) var detectedTrackCount: Int?
    /// One snapshot every progress surface renders — the in-app preparation screen and the iOS
    /// Live Activity — instead of each reaching into the index and cover services.
    private(set) var progress = LibraryPreparationProgress()

    private let liveActivity: LibraryPreparationLiveActivityController?
    private var ownsPreparationPass = false
    /// Resolves the active server's display name for the Live Activity (injected so this service
    /// stays free of the container).
    private let serverName: @MainActor () -> String
    /// Asks the app to schedule a background window so a long pass can resume when iOS grants one.
    private let requestBackgroundContinuation: @MainActor () -> Void

    init(
        liveActivity: LibraryPreparationLiveActivityController? = nil,
        serverName: @escaping @MainActor () -> String = { "" },
        requestBackgroundContinuation: @escaping @MainActor () -> Void = {}
    ) {
        self.liveActivity = liveActivity
        self.serverName = serverName
        self.requestBackgroundContinuation = requestBackgroundContinuation
    }

    /// One preparation pass at a time; a second call while busy is ignored.
    func prepareIfLibraryChanged(
        serverService: any ServerServiceProtocol,
        libraryService: any LibraryServiceProtocol,
        indexService: LibraryIndexService,
        coverPreload: AlbumCoverPreloadService
    ) async {
        // A cover-only pass may be running: onboarding's first download, or a launch resuming one
        // that was interrupted. Wait for it rather than skipping the change check, which would
        // leave the local index stale until the next launch.
        while phase == .covers, !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
        }
        guard !phase.isBusy, !Task.isCancelled else { return }
        guard let serverId = serverService.state.activeServer?.id else { return }
        if indexService.isPreparing {
            _ = await indexService.ensureIndexedAndWait(using: libraryService)
            guard !Task.isCancelled, !phase.isBusy, serverId == serverService.state.activeServer?.id else { return }
        }
        phase = .checking
        publish(.init(phase: .checking))
        defer { detectedTrackCount = nil }

        // A scan that cannot be read is not a reason to block the app: treat it as "no change".
        let status = try? await LibraryScanService.status(serverService: serverService)
        guard !Task.isCancelled, serverId == serverService.state.activeServer?.id,
              status?.scanning != true else { finish(phase: .idle); return }
        let serverCount = status?.count

        guard LibraryChangeDetector.needsPreparation(
            storedCount: LibraryChangeDetector.storedCount(for: serverId),
            serverCount: serverCount
        ) || LibraryChangeDetector.needsMetadataRefresh(lastIndexedAt: indexService.lastIndexedAt,
                                                        lastScan: status?.lastScan) else {
            // First observation (or nothing changed): record the count so the next launch compares.
            if let serverCount {
                LibraryChangeDetector.store(count: serverCount, for: serverId)
            }
            finish(phase: .idle)
            return
        }

        ownsPreparationPass = true
        defer { ownsPreparationPass = false }
        detectedTrackCount = serverCount
        Logger.library.notice(
            "[LIBRARY-PREP] server reports \(serverCount ?? -1, privacy: .public) files — preparing"
        )
        // The pass is resumable (every cover checks the disk first), so a background window only has
        // to keep it going instead of restarting it.
        requestBackgroundContinuation()

        phase = .indexing
        publish(.init(phase: .indexing))
        let indexReady = await indexService.rebuildAndWait(using: libraryService)
        guard !Task.isCancelled else {
            finish(phase: .idle)
            return
        }
        guard indexReady else {
            finish(phase: .failed)
            return
        }

        if BulkArtworkPreference.isEnabled {
            phase = .covers
            publish(.init(phase: .covers, coversCompleted: coverPreload.state.availableCompleted, coversTotal: coverPreload.state.libraryTotal, indexFraction: 1))
            await coverPreload.downloadAllCovers(resumeDeferred: false) { [weak self] completed, total, coverId in
                guard let self else { return }
                self.publish(.init(
                    phase: .covers,
                    coversCompleted: completed,
                    coversTotal: total,
                    indexFraction: 1,
                    activeCoverArtId: coverId
                ))
            }
            guard !Task.isCancelled else {
                finish(phase: .idle)
                return
            }
            guard coverPreload.state.isComplete else {
                requestBackgroundContinuation()
                finish(phase: .failed)
                return
            }
        }

        phase = .syncing
        publish(.init(
            phase: .syncing,
            coversCompleted: progress.coversCompleted,
            coversTotal: progress.coversTotal,
            indexFraction: 1
        ))
        // Home/Discover sections were built from the previous catalog; the album-cover snapshot is
        // refreshed by the pass above, and the index now reflects the new one.
        DiscoverSectionsCache.clear()
        if let serverCount {
            LibraryChangeDetector.store(count: serverCount, for: serverId)
        }
        Logger.library.notice("[LIBRARY-PREP] preparation complete")

        finish(phase: .complete)
    }

    /// Called after a finish/cancel so the next launch re-checks instead of reusing stale state.
    func reset() {
        phase = .idle
        progress = LibraryPreparationProgress()
        detectedTrackCount = nil
    }

    // MARK: - Progress

    /// Accepts cover-stage progress from a pass this service does not own — onboarding's first
    /// download, or a launch that found the previous one incomplete.
    ///
    /// The Live Activity and localized phase title stay here, so
    /// there is exactly one place that talks to ActivityKit no matter who started the work.
    func receiveExternalProgress(_ snapshot: LibraryPreparationProgress) {
        // Ignore a cover pass that finished while this service was rebuilding the index or dropping
        // caches: that pass owns the screen until it is done.
        guard !ownsPreparationPass, !phase.isBusy || phase == .covers else { return }
        phase = snapshot.phase
        publish(snapshot)
    }

    private func publish(_ snapshot: LibraryPreparationProgress) {
        guard progress != snapshot else { return }
        progress = snapshot
        liveActivity?.update(
            with: snapshot,
            phaseTitle: Self.localizedTitle(for: snapshot.phase),
            serverName: serverName()
        )
    }

    /// Terminal transition that keeps the counters so the activity's final frame is coherent.
    private func finish(phase newPhase: Phase) {
        phase = newPhase
        publish(.init(
            phase: newPhase,
            coversCompleted: progress.coversCompleted,
            coversTotal: progress.coversTotal,
            indexFraction: progress.indexFraction
        ))
    }

    /// Localized phase label. The Live Activity displays this verbatim, so it must be resolved here:
    /// the widget extension has no string catalogue of its own.
    private static func localizedTitle(for phase: Phase) -> String {
        let key: String
        switch phase {
        case .idle, .checking: key = "Checking your library"
        case .indexing: key = "Library indexing"
        case .covers: key = "Album covers and background colors"
        case .syncing: key = "Syncing your library"
        case .complete: key = "Library update complete"
        case .failed: key = "Library update failed"
        }
        return String(
            localized: String.LocalizationValue(key),
            bundle: AppUILanguage.localizationBundle,
            locale: AppUILanguage.locale
        )
    }
}
