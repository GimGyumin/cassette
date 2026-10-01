// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import SwiftSonic

/// Aligns a secondary lyric layer (pronunciation / translation) onto primary lines.
enum LyricsLayerAligner {
    /// Returns one secondary string per primary line (empty when unmatched).
    static func align(primary: [Line], secondary: [Line]) -> [String] {
        guard !primary.isEmpty else { return [] }
        if secondary.isEmpty {
            return Array(repeating: "", count: primary.count)
        }
        if primary.count == secondary.count {
            return secondary.map(\.value)
        }

        return primary.map { line in
            guard let start = line.start else { return "" }
            var best: Line?
            var bestDelta = Int.max
            for candidate in secondary {
                guard let cStart = candidate.start else { continue }
                let delta = abs(cStart - start)
                if delta < bestDelta {
                    bestDelta = delta
                    best = candidate
                }
            }
            // Allow ±2s matching window for loosely aligned layers.
            guard bestDelta <= 2_000, let best else { return "" }
            return best.value
        }
    }

    static func pronunciation(for primary: StructuredLyrics, in list: LyricsList) -> StructuredLyrics? {
        let lang = normalize(primary.lang)
        let candidates = list.structuredLyrics.filter { $0.kind == .pronunciation }
        if let lang {
            return candidates.first(where: { normalize($0.lang) == lang }) ?? candidates.first
        }
        return candidates.first
    }

    static func translationTracks(in list: LyricsList) -> [StructuredLyrics] {
        list.structuredLyrics.filter { $0.kind == .translation && !$0.line.isEmpty }
    }

    static func normalize(_ lang: String?) -> String? {
        guard let lang, !lang.isEmpty else { return nil }
        return lang == "xxx" ? "und" : lang
    }
}
