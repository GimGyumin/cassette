// Swift adaptation of AMLL, AGPL-3.0-only; Copyright the AMLL contributors.
// Swift adaptation Copyright (C) 2026 Cassette contributors.
// Upstream 5fee356362353dbb24ce9bea3a62536478040de7:
// packages/core/src/lyric-player/base/timeline.ts (TimelineController).
// See Resources/Licenses/AMLL-AGPL-3.0.txt. Value snapshots replace the JS diff object pool.

import Foundation

nonisolated struct AMLLTimeline: Sendable {
    struct Bounds: Equatable, Sendable { let start: Int; let end: Int }
    struct Interlude: Equatable, Sendable { let start: Int; let end: Int; let after: Int }
    struct Snapshot: Equatable, Sendable {
        var time = 0
        var playing: Set<Int> = []
        var highlighted: Set<Int> = []
        var scrollIndex = 0
        var ended = false
        var interlude: Interlude?
        var focusesInterlude: Bool { interlude != nil && highlighted.isEmpty }
    }
    private let bounds: [Bounds]
    private let gaps: [Interlude]
    private let maximumEnd: Int
    private var cursor = 0
    private var gapCursor = 0
    private var initialized = false
    private(set) var snapshot = Snapshot()

    /// Input is ordered by start time; the native adapter retains display-index mapping.
    init(bounds: [Bounds]) {
        self.bounds = bounds
        maximumEnd = bounds.map(\.end).max() ?? 0
        var gaps: [Interlude] = [], maximum = 0
        for i in bounds.indices {
            let next = bounds[i].start
            if next - maximum >= 7000 { gaps.append(Interlude(start: maximum, end: next, after: i - 1)) }
            maximum = max(maximum, bounds[i].end)
        }
        self.gaps = gaps
    }

    @discardableResult mutating func sync(_ time: Int, seeking: Bool = false) -> Snapshot {
        let jump = seeking || !initialized || time < snapshot.time
        initialized = true
        if jump {
            gapCursor = firstIndex(in: gaps.count) { gaps[$0].end > time }
        }
        while gapCursor < gaps.count && time >= gaps[gapCursor].end { gapCursor += 1 }
        snapshot.interlude = gapCursor < gaps.count && time >= gaps[gapCursor].start ? gaps[gapCursor] : nil
        snapshot.ended = !bounds.isEmpty && time >= maximumEnd
        if jump { seek(time, dropLingering: snapshot.interlude != nil || snapshot.ended) }
        else { advance(time) }
        if (snapshot.interlude != nil && snapshot.playing.isEmpty) || snapshot.ended {
            snapshot.highlighted.removeAll(keepingCapacity: true)
        }
        snapshot.time = time
        return snapshot
    }

    private mutating func advance(_ time: Int) {
        snapshot.playing = snapshot.playing.filter { bounds[$0].start <= time && time < bounds[$0].end }
        var added: Set<Int> = []
        while cursor < bounds.count && bounds[cursor].start <= time {
            if time < bounds[cursor].end && !snapshot.playing.contains(cursor) { added.insert(cursor); snapshot.playing.insert(cursor) }
            cursor += 1
        }
        if !added.isEmpty {
            // Expired overlapping vocals stay bright until another group actually starts.
            snapshot.highlighted.formIntersection(snapshot.playing)
            snapshot.highlighted.formUnion(added)
            snapshot.scrollIndex = snapshot.highlighted.min() ?? snapshot.scrollIndex
        }
    }

    private mutating func seek(_ time: Int, dropLingering: Bool) {
        let firstGreater = firstIndex(in: bounds.count) { bounds[$0].start > time }
        snapshot.playing.removeAll(keepingCapacity: true)
        snapshot.highlighted.removeAll(keepingCapacity: true)
        guard let anchor = (0..<firstGreater).reversed().first(where: { bounds[$0].end > bounds[$0].start }) else {
            cursor = firstGreater; snapshot.scrollIndex = 0; return
        }
        let anchorStart = bounds[anchor].start
        for i in stride(from: anchor, through: 0, by: -1) where bounds[i].end > anchorStart {
            snapshot.highlighted.insert(i)
            if bounds[i].start <= time && time < bounds[i].end { snapshot.playing.insert(i) }
        }
        snapshot.scrollIndex = snapshot.highlighted.min() ?? anchor
        if dropLingering && snapshot.playing.isEmpty { snapshot.highlighted.removeAll(keepingCapacity: true) }
        cursor = snapshot.playing.min() ?? firstGreater
    }

    private func firstIndex(in count: Int, matching: (Int) -> Bool) -> Int {
        var low = 0, high = count
        while low < high {
            let mid = low + (high - low) / 2
            if matching(mid) { high = mid } else { low = mid + 1 }
        }
        return low
    }
}
