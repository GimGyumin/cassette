// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.

import Foundation

/// Immutable, text-free timing data. Build once when display rows change, not
/// on every karaoke frame. Row order and overlapping vocal parts are preserved.
nonisolated struct LyricPlaybackTimeline: Sendable {
    private struct Entry: Sendable {
        let index: Int
        let start: Int
        let end: Int?
        let secondary: Bool
    }

    private let entries: [Entry]

    init(rows: [LyricDisplayRow]) {
        entries = rows.enumerated().compactMap { index, row in
            guard let start = row.startMs,
                  !row.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return Entry(index: index, start: start, end: row.endMs, secondary: row.isSecondaryAgent)
        }
    }

    func activeRows(for milliseconds: Int) -> (primary: Int?, indices: Set<Int>) {
        var indices = Set<Int>()
        var primaryLead: Entry?
        var primaryAny: Entry?
        var upcomingLead: Entry?

        for entry in entries {
            if entry.start > milliseconds {
                if upcomingLead == nil, !entry.secondary { upcomingLead = entry }
                continue
            }
            if let end = entry.end, milliseconds >= end { continue }
            indices.insert(entry.index)
            if primaryAny.map({ entry.start > $0.start }) ?? true { primaryAny = entry }
            // A simultaneous lead keeps the first display row as primary.
            if !entry.secondary,
               primaryLead.map({ entry.start > $0.start }) ?? true {
                primaryLead = entry
            }
        }

        if indices.isEmpty {
            if let upcomingLead { return (upcomingLead.index, [upcomingLead.index]) }
            return (nil, [])
        }
        return (primaryLead?.index ?? primaryAny?.index, indices)
    }
}
