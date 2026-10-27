// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import OSLog

/// Correlates lifecycle and request events without recording account or media identities.
nonisolated enum RuntimeDiagnostics {
    static let sessionID = String(UUID().uuidString.prefix(8))
    private static let started = ContinuousClock.now

    enum Milestone: String { case appInit, rootAppeared, setupReady, libraryReady, playbackReady }

    static func mark(_ milestone: Milestone) {
        let elapsed = milliseconds(started.duration(to: .now))
        Logger.boot.notice("[LIFECYCLE] session=\(sessionID, privacy: .public) event=\(milestone.rawValue, privacy: .public) since_app_init_ms=\(elapsed, privacy: .public)")
    }

    static func milliseconds(_ duration: Duration) -> Int64 {
        let parts = duration.components
        return parts.seconds * 1_000 + parts.attoseconds / 1_000_000_000_000_000
    }
}
