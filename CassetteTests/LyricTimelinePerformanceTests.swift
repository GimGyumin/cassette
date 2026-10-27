import Foundation
import XCTest
@testable import Cassette

/// In-process algorithm comparison. These numbers are not device playback/energy metrics.
final class LyricTimelinePerformanceTests: XCTestCase {
    private func rows() -> [LyricDisplayRow] {
        (0..<4000).map { index in
            LyricDisplayRow(sourceLineIndex: index, text: "Timed phrase", startMs: index * 1000,
                            endMs: index * 1000 + 1500, cueLine: nil,
                            isSecondaryAgent: index % 4 == 3, speakerSide: .leading)
        }
    }

    private func run(_ lookup: (Int) -> (primary: Int?, indices: Set<Int>)) {
        var checksum = 0
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(metrics: [XCTClockMetric(), XCTCPUMetric()], options: options) {
            for index in 0..<2000 {
                // Repeatable large forward/backward seeks, including overlapping rows.
                let result = lookup((index * 7919) % 4_000_000)
                checksum &+= (result.primary ?? 0) + result.indices.count
            }
        }
        XCTAssertGreaterThan(checksum, 0)
    }

    func testIndexedTimeline() {
        let timeline = LyricPlaybackTimeline(rows: rows())
        run(timeline.activeRows(for:))
    }

    func testLinearBaseline() {
        let timeline = LinearLyricTimelineBaseline(rows: rows())
        run(timeline.activeRows(for:))
    }
}

// Exact cached linear algorithm from the pre-change working tree, retained for A/B measurement.
nonisolated private struct LinearLyricTimelineBaseline: Sendable {
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
