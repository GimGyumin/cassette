// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import OSLog
import SwiftSonic

/// External lyrics via LRCLIB (and any future providers).
nonisolated struct CompositeExternalLyricsClient: ExternalLyricsProviding {
    private let lrclib = LRCLIBClient()

    func fetchLyrics(match: LyricsMatchInfo) async throws -> LyricsList {
        try await lrclib.fetchLyrics(match: match)
    }
}
