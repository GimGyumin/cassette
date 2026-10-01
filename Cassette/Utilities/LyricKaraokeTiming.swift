// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import SwiftSonic

/// Helpers for OpenSubsonic songLyrics v2 karaoke cues (UTF-8 byte offsets).
nonisolated enum LyricKaraokeTiming {
    /// All cue lines for a lyric line index (lead + backing), main agent first.
    static func cueLines(for lineIndex: Int, in structured: StructuredLyrics) -> [CueLine] {
        let matches = structured.cueLine.filter { $0.index == lineIndex && !$0.cue.isEmpty }
        guard matches.count > 1 else { return matches }
        let mainId = structured.agents.first(where: { $0.role == "main" })?.id
        return matches.sorted { a, b in
            let aMain = mainId != nil && a.agentId == mainId
            let bMain = mainId != nil && b.agentId == mainId
            if aMain != bMain { return aMain && !bMain }
            return (a.cue.first?.start ?? a.start ?? 0) < (b.cue.first?.start ?? b.start ?? 0)
        }
    }

    /// Prefer the main-agent cue line for a lyric line index, else the first match.
    static func preferredCueLine(for lineIndex: Int, in structured: StructuredLyrics) -> CueLine? {
        cueLines(for: lineIndex, in: structured).first
    }

    /// Index of the latest cue whose `start` is ≤ `adjustedMs`, or `nil` if none yet.
    static func activeCueIndex(in cueLine: CueLine, adjustedMs: Int) -> Int? {
        var found: Int?
        for (index, cue) in cueLine.cue.enumerated() {
            if cue.start <= adjustedMs {
                found = index
            } else {
                break
            }
        }
        return found
    }

    /// Inclusive UTF-8 byte end of the active cue (for progressive highlight).
    static func activeByteEnd(in cueLine: CueLine, cueIndex: Int?) -> Int? {
        guard let cueIndex, cueLine.cue.indices.contains(cueIndex) else { return nil }
        return cueLine.cue[cueIndex].byteEnd
    }

    static func activeByteEnd(in cueLine: CueLine?, adjustedMs: Int) -> Int? {
        guard let cueLine else { return nil }
        let cueIndex = activeCueIndex(in: cueLine, adjustedMs: adjustedMs)
        return activeByteEnd(in: cueLine, cueIndex: cueIndex)
    }
}
