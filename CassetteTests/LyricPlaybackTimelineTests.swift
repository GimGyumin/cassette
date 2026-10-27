import Foundation
import Testing
@testable import Cassette

@Suite("Cached lyric playback timeline")
struct LyricPlaybackTimelineTests {
    @Test func indexedLookupMatchesDisplayOrderScanAcrossSeeksAndOverlaps() {
        var seed: UInt64 = 42
        func random(_ limit: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1
            return Int((seed >> 32) % UInt64(limit))
        }
        let rows = (0..<2000).map { index in
            let start = random(200_000) - 1000
            return row(index % 31 == 0 ? nil : start,
                       end: index % 19 == 0 ? nil : start + random(8000) - 200,
                       secondary: index % 3 == 0, text: index % 37 == 0 ? " \n" : "Verse")
        }
        let timeline = LyricPlaybackTimeline(rows: rows)
        for time in [Int.min, Int.max] + (0..<500).map({ _ in random(220_000) - 2000 }) {
            let expected = reference(rows, time: time)
            let actual = timeline.activeRows(for: time)
            #expect(actual.primary == expected.primary)
            #expect(actual.indices == expected.indices)
        }
    }

    /// Keep the pre-optimization algorithm as an independent semantic oracle.
    private func reference(_ rows: [LyricDisplayRow], time: Int) -> (primary: Int?, indices: Set<Int>) {
        var active: Set<Int> = []
        var primary: Int?, any: Int?, upcoming: Int?
        for (index, row) in rows.enumerated() {
            guard let start = row.startMs, !row.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            if start > time {
                if upcoming == nil, !row.isSecondaryAgent { upcoming = index }
                continue
            }
            if let end = row.endMs, time >= end { continue }
            active.insert(index)
            if any == nil || start > rows[any!].startMs! { any = index }
            if !row.isSecondaryAgent, primary == nil || start > rows[primary!].startMs! { primary = index }
        }
        if active.isEmpty { return (upcoming, upcoming.map { [$0] } ?? []) }
        return (primary ?? any, active)
    }

    private func row(_ start: Int?, end: Int? = nil, secondary: Bool = false,
                     text: String = "Verse") -> LyricDisplayRow {
        LyricDisplayRow(sourceLineIndex: 0, text: text, startMs: start,
                        endMs: end, cueLine: nil, isSecondaryAgent: secondary,
                        speakerSide: .leading)
    }

    @Test func overlappingLeadsKeepDisplayOrderForTies() {
        let timeline = LyricPlaybackTimeline(rows: [
            row(0, end: 5000), row(1000, end: 3000),
            row(1000, end: 3000), row(1500, end: 2500, secondary: true)
        ])
        let active = timeline.activeRows(for: 2000)
        #expect(active.primary == 1)
        #expect(active.indices == [0, 1, 2, 3])
        #expect(timeline.activeRows(for: 3000).indices == [0])
        #expect(timeline.activeRows(for: 5000).primary == nil)
    }

    @Test func untimedAndBlankRowsAreIgnoredAndGapsKeepUpcomingLead() {
        let timeline = LyricPlaybackTimeline(rows: [
            row(nil), row(0, text: " \n"), row(0, end: 500),
            row(1000, end: 1500, secondary: true), row(2000, end: 3000)
        ])
        #expect(timeline.activeRows(for: 750).primary == 4)
        #expect(timeline.activeRows(for: 1000).primary == 3)
        #expect(timeline.activeRows(for: 2000).primary == 4)
        // Backward seeks are stateless; there is no stale forward-only cursor.
        #expect(timeline.activeRows(for: 100).primary == 2)
        #expect(timeline.activeRows(for: 3000).indices.isEmpty)
    }

    @Test func replacementDoesNotKeepOldTimings() {
        var timeline = LyricPlaybackTimeline(rows: [row(0), row(1000)])
        #expect(timeline.activeRows(for: 1500).primary == 1)
        timeline = LyricPlaybackTimeline(rows: [])
        #expect(timeline.activeRows(for: 1500).primary == nil)
        #expect(timeline.activeRows(for: 1500).indices.isEmpty)
    }
}
