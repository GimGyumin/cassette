import Testing
@testable import Cassette

@Suite("Cached lyric playback timeline")
struct LyricPlaybackTimelineTests {
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
