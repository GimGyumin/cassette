// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation

/// Which part of the library-preparation pass is running.
///
/// Shared between the app and the widget extension, and modelled outside `#if os(iOS)` because the
/// in-app preparation screen uses it on every platform — macOS has no Live Activities but still
/// shows the same phases.
nonisolated enum LibraryPreparationPhase: String, Codable, Sendable, Equatable {
    case idle
    /// Asking the server whether the library changed.
    case checking
    /// Rebuilding the local artist/album/playlist index.
    case indexing
    /// Reconciling downloaded album artwork.
    case covers
    /// Dropping caches built from the previous catalog.
    case syncing
    case complete
    case failed

    /// True while a pass is running — gates a second pass from starting.
    var isBusy: Bool {
        switch self {
        case .idle, .complete, .failed: return false
        case .checking, .indexing, .covers, .syncing: return true
        }
    }

    /// Checking for changes is silent; only actual preparation should interrupt the UI.
    var isPreparing: Bool {
        switch self {
        case .indexing, .covers, .syncing: return true
        case .idle, .checking, .complete, .failed: return false
        }
    }
}

/// Platform-neutral snapshot of the pass, published by `LibraryPreparationService`.
///
/// Anything that renders progress — the in-app screen, the Live Activity, a future widget — reads
/// this one value instead of reaching into two services.
nonisolated struct LibraryPreparationProgress: Sendable, Equatable {
    var phase: LibraryPreparationPhase = .idle
    var coversCompleted: Int = 0
    var coversTotal: Int = 0
    /// Library index progress, 0…1.
    var indexFraction: Double = 0
    /// Cover currently being prepared, so a Live Activity can show real artwork.
    var activeCoverArtId: String?

    /// Cover pass fraction, 0…1.
    var coverFraction: Double {
        guard coversTotal > 0 else { return 0 }
        return min(1, max(0, Double(coversCompleted) / Double(coversTotal)))
    }
}

#if os(iOS)
import ActivityKit

/// Live Activity shown while the library is being updated (indexing + album artwork).
///
/// Apple's guidance is that a Live Activity tracks a task the user is actively following, so it is
/// started when a preparation pass begins — which is exactly when the app puts
/// `LibraryPreparationView` on screen — and ended when the pass finishes or fails.
///
/// The **phase title is localized by the app** and travels inside `ContentState`: the widget
/// extension has no string catalogue of its own, so it renders whatever text it is given.
nonisolated struct LibraryPreparationActivityAttributes: ActivityAttributes {

    nonisolated struct ContentState: Codable, Hashable {
        /// Already-localized phase label (for example "Preparing album covers").
        var phaseTitle: String
        /// Optional for decoding activities created by older app versions.
        var phase: LibraryPreparationPhase? = nil
        var coversCompleted: Int
        var coversTotal: Int
        var indexFraction: Double
        /// Cover being prepared right now, if any.
        var activeCoverArtId: String?
        /// True once the pass reached a terminal state.
        var isFinished: Bool
        var failed: Bool
        var backgroundRGB: Int? = nil
        var estimatedCompletion: Date? = nil
        var etaTitle: String? = nil

        var fraction: Double? {
            if isFinished && !failed { return 1 }
            if phase == .syncing { return nil }
            if (phase == .covers || phase == nil), coversTotal > 0 {
                return min(1, max(0, Double(coversCompleted) / Double(coversTotal)))
            }
            guard indexFraction.isFinite, indexFraction > 0 else { return nil }
            return min(1, max(0, indexFraction))
        }

        var symbol: String {
            if failed { return "exclamationmark.triangle.fill" }
            if isFinished { return "checkmark" }
            return phase == .covers ? "photo.stack" : "music.note.list"
        }
    }

    /// Constant for the lifetime of the activity.
    var serverName: String

    /// Builds the activity payload from a progress snapshot. `title` must already be localized.
    static func state(
        from progress: LibraryPreparationProgress,
        title: String,
        isFinished: Bool,
        failed: Bool
    ) -> ContentState {
        ContentState(
            phaseTitle: title,
            phase: progress.phase,
            coversCompleted: progress.coversCompleted,
            coversTotal: progress.coversTotal,
            indexFraction: progress.indexFraction,
            activeCoverArtId: nil,
            isFinished: isFinished,
            failed: failed
        )
    }
}
#endif
