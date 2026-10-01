// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Testing
import Foundation
import SwiftSonic
@testable import Cassette

@Suite("LyricDisplayBuilder")
struct LyricDisplayBuilderTests {

    @Test func singleAgent_keepsParentLine() {
        let cue = LyricCue(start: 1000, value: "Hello", byteStart: 0, byteEnd: 4)
        let structured = StructuredLyrics(
            lang: "en",
            synced: true,
            line: [Line(value: "Hello", start: 1000)],
            cueLine: [CueLine(index: 0, start: 1000, value: "Hello", cue: [cue])]
        )
        let rows = LyricDisplayBuilder.rows(from: structured)
        #expect(rows.count == 1)
        #expect(rows[0].text.contains("Hello"))
        #expect(rows[0].startMs == 1000)
        #expect(rows[0].isSecondaryAgent == false)
        #expect(rows[0].speakerSide == .leading)
        #expect(rows[0].mainWords.count == 1)
    }

    @Test func multiAgent_sameIndex_mergesBackgroundUnderLead() {
        let structured = StructuredLyrics(
            lang: "en",
            synced: true,
            line: [
                Line(value: "Just lift yourself (Change)", start: 120_400),
                Line(value: "You know, you've got to start with yourself", start: 122_100),
            ],
            agents: [
                LyricsAgent(id: "lead", role: "main"),
                LyricsAgent(id: "choir", role: "bg"),
            ],
            cueLine: [
                CueLine(
                    index: 0,
                    start: 120_400,
                    value: "Just lift yourself",
                    agentId: "lead",
                    cue: [
                        LyricCue(start: 120_400, end: 121_000, value: "Just", byteStart: 0, byteEnd: 3),
                        LyricCue(start: 121_000, end: 122_000, value: " lift yourself", byteStart: 4, byteEnd: 17),
                    ]
                ),
                CueLine(
                    index: 0,
                    start: 120_150,
                    value: "(Change)",
                    agentId: "choir",
                    cue: [
                        LyricCue(start: 120_150, end: 120_800, value: "(Change)", byteStart: 0, byteEnd: 7),
                    ]
                ),
                CueLine(
                    index: 1,
                    start: 122_100,
                    value: "You know, you've got to start with yourself",
                    agentId: "lead",
                    cue: [
                        LyricCue(start: 122_100, end: 123_000, value: "You know", byteStart: 0, byteEnd: 7),
                    ]
                ),
            ]
        )
        let rows = LyricDisplayBuilder.rows(from: structured)
        #expect(rows.count == 2)
        #expect(rows[0].backgroundWords.count == 1)
        #expect(rows[0].mainWords.count == 2)
        #expect(rows[0].isSecondaryAgent == false)
        #expect(rows[1].text.contains("You know"))
    }

    @Test func chronologicallyOrdered_ignoresLeadGrouping() {
        let rows = [
            LyricDisplayRow(
                sourceLineIndex: 0,
                text: "Just lift yourself",
                startMs: 120_400,
                endMs: nil,
                cueLine: nil,
                isSecondaryAgent: false,
                speakerSide: .leading
            ),
            LyricDisplayRow(
                sourceLineIndex: 0,
                text: "(Change)",
                startMs: 120_150,
                endMs: nil,
                cueLine: nil,
                isSecondaryAgent: true,
                speakerSide: .leading
            ),
            LyricDisplayRow(
                sourceLineIndex: 1,
                text: "You've got to start",
                startMs: 122_100,
                endMs: nil,
                cueLine: nil,
                isSecondaryAgent: false,
                speakerSide: .leading
            ),
        ]
        let ordered = LyricDisplayBuilder.chronologicallyOrdered(rows)
        #expect(ordered.map(\.text) == [
            "(Change)",
            "Just lift yourself",
            "You've got to start",
        ])
    }

    @Test func activeRows_mostRecentStartBecomesPrimary() {
        let rows = [
            LyricDisplayRow(
                sourceLineIndex: 0,
                text: "Early lead",
                startMs: 1000,
                endMs: 5000,
                cueLine: nil,
                isSecondaryAgent: false,
                speakerSide: .leading
            ),
            LyricDisplayRow(
                sourceLineIndex: 1,
                text: "Late duplicate",
                startMs: 3000,
                endMs: 5000,
                cueLine: nil,
                isSecondaryAgent: false,
                speakerSide: .leading
            ),
        ]
        // Both rows active at 4000 — "most recent start" (3000) is primary.
        let result = LyricDisplayBuilder.activeRows(for: 4000, in: rows)
        #expect(result.primary == 1)
        #expect(result.indices == [0, 1])
    }

    @Test func activeRows_secondaryFallbackStillSelectsMostRecent() {
        let rows = [
            LyricDisplayRow(
                sourceLineIndex: 0,
                text: "(backing one)",
                startMs: 1000,
                endMs: 5000,
                cueLine: nil,
                isSecondaryAgent: true,
                speakerSide: .leading
            ),
            LyricDisplayRow(
                sourceLineIndex: 1,
                text: "(backing two)",
                startMs: 4000,
                endMs: 6000,
                cueLine: nil,
                isSecondaryAgent: true,
                speakerSide: .leading
            ),
        ]
        // No lead rows — secondary fallback picks the most recent start (4000).
        let result = LyricDisplayBuilder.activeRows(for: 4500, in: rows)
        #expect(result.primary == 1)
        #expect(result.indices == [0, 1])
    }

    @Test func timelineProgress_beginEqualsEnd_hasNoNaN() {
        // begin == end → span clamps to 0.001, no division by zero / NaN.
        let word = LyricWord(text: "x", begin: 1.0, end: 1.0, role: .main)
        let progress = LyricTimelineQuery.progress(for: word, at: 1.0)
        #expect(progress.isFinite)
        #expect(progress >= 0 && progress <= 1)
    }

    @Test func speakerSide_secondMainAgentIsTrailing() {
        #expect(
            LyricDisplayBuilder.speakerSide(
                for: LyricsAgent(id: "v2", role: "main"),
                mainAgentId: "v1",
                cue: nil,
                siblings: [],
                multiSpeaker: true
            ) == .trailing
        )
        #expect(
            LyricDisplayBuilder.speakerSide(
                for: LyricsAgent(id: "v1", role: ""),
                mainAgentId: "v1",
                cue: nil,
                siblings: [],
                multiSpeaker: true
            ) == .leading
        )
    }

    @Test func activeRows_overlappingLeadAndChoirBothActive_viaMergedWords() {
        // After merge, choir lives on the same row as background words — row stays active
        // through max(main, bg) end unless clipped by next lead.
        let rows = LyricDisplayBuilder.rows(from: StructuredLyrics(
            lang: "en",
            synced: true,
            line: [Line(value: "change", start: 1000)],
            agents: [
                LyricsAgent(id: "lead", role: "main"),
                LyricsAgent(id: "backing", role: "bg"),
            ],
            cueLine: [
                CueLine(
                    index: 0,
                    start: 1000,
                    end: 3500,
                    value: "change his ways",
                    agentId: "lead",
                    cue: [
                        LyricCue(start: 1000, end: 2000, value: "change", byteStart: 0, byteEnd: 5),
                        LyricCue(start: 2000, end: 3500, value: " his ways", byteStart: 6, byteEnd: 14),
                    ]
                ),
                CueLine(
                    index: 0,
                    start: 2200,
                    end: 4000,
                    value: "(Come on, change)",
                    agentId: "backing",
                    cue: [
                        LyricCue(start: 2200, end: 4000, value: "(Come on, change)", byteStart: 0, byteEnd: 16),
                    ]
                ),
            ]
        ))
        #expect(rows.count == 1)
        let overlapping = LyricDisplayBuilder.activeRows(for: 2500, in: rows)
        #expect(overlapping.indices.contains(0))
    }

    @Test func activeRows_backingClipsWhenNextLeadArrivesEarly() {
        let rows = LyricDisplayBuilder.withPrecomputedEnds([
            LyricDisplayRow(
                sourceLineIndex: 0,
                text: "(falling)",
                startMs: 11_000,
                endMs: 14_000,
                cueLine: nil,
                isSecondaryAgent: true,
                speakerSide: .leading
            ),
            LyricDisplayRow(
                sourceLineIndex: 1,
                text: "Don't let me go",
                startMs: 12_200,
                endMs: 14_500,
                cueLine: nil,
                isSecondaryAgent: false,
                speakerSide: .leading
            ),
        ])
        #expect(rows[0].endMs == 12_200)
        let after = LyricDisplayBuilder.activeRows(for: 12_500, in: rows)
        #expect(after.indices == [1])
    }
}
