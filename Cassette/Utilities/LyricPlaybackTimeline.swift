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
    private let leafCount: Int
    private let maximumEnds: [Int]
    private let upcomingLeads: [Int?]

    init(rows: [LyricDisplayRow]) {
        let entries = rows.enumerated().compactMap { index, row -> Entry? in
            guard let start = row.startMs,
                  !row.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return Entry(index: index, start: start, end: row.endMs, secondary: row.isSecondaryAgent)
        }.sorted { ($0.start, $0.index) < ($1.start, $1.index) }
        self.entries = entries
        var leaves = 1
        while leaves < entries.count { leaves *= 2 }
        leafCount = leaves
        var ends = Array(repeating: Int.min, count: leaves * 2)
        for index in entries.indices { ends[leaves + index] = entries[index].end ?? Int.max }
        if leaves > 1 {
            for index in stride(from: leaves - 1, through: 1, by: -1) {
                ends[index] = max(ends[index * 2], ends[index * 2 + 1])
            }
        }
        maximumEnds = ends
        // Preserve the original display-order fallback even for unsorted input.
        var upcoming = [Int?](repeating: nil, count: entries.count + 1)
        for index in entries.indices.reversed() {
            let next = upcoming[index + 1]
            upcoming[index] = entries[index].secondary ? next
                : min(entries[index].index, next ?? entries[index].index)
        }
        upcomingLeads = upcoming
    }

    func activeRows(for milliseconds: Int) -> (primary: Int?, indices: Set<Int>) {
        var indices = Set<Int>()
        var primaryLead: Entry?
        var primaryAny: Entry?
        var low = 0, high = entries.count
        while low < high {
            let middle = low + (high - low) / 2
            if entries[middle].start <= milliseconds { low = middle + 1 }
            else { high = middle }
        }
        let firstFuture = low
        // Skip entire expired subtrees. Cost follows active overlap, rather than the
        // document length, without a forward-only cursor that could break backward seeks.
        func collect(_ node: Int, _ lower: Int, _ upper: Int) {
            guard lower < firstFuture, maximumEnds[node] >= milliseconds else { return }
            if upper - lower > 1 {
                let middle = lower + (upper - lower) / 2
                collect(node * 2, lower, middle)
                collect(node * 2 + 1, middle, upper)
                return
            }
            let entry = entries[lower]
            if let end = entry.end, milliseconds >= end { return }
            indices.insert(entry.index)
            if primaryAny.map({ entry.start > $0.start || (entry.start == $0.start && entry.index < $0.index) }) ?? true { primaryAny = entry }
            // A simultaneous lead keeps the first display row as primary.
            if !entry.secondary,
               primaryLead.map({ entry.start > $0.start || (entry.start == $0.start && entry.index < $0.index) }) ?? true {
                primaryLead = entry
            }
        }
        collect(1, 0, leafCount)

        if indices.isEmpty {
            if let upcomingLead = upcomingLeads[firstFuture] { return (upcomingLead, [upcomingLead]) }
            return (nil, [])
        }
        return (primaryLead?.index ?? primaryAny?.index, indices)
    }
}
