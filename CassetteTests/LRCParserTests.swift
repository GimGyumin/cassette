// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Testing
import SwiftSonic
@testable import Cassette

@Suite("LRCParser")
struct LRCParserTests {
    @Test func parseSynced_basicTimestamps() {
        let lrc = """
        [ti:Test]
        [00:17.12] Hello world
        [01:02.5] Second line
        [02:03.456] Third
        """
        let lines = LRCParser.parseSynced(lrc)
        #expect(lines.count == 3)
        #expect(lines[0].value == "Hello world")
        #expect(lines[0].start == 17_120)
        #expect(lines[1].value == "Second line")
        #expect(lines[1].start == 62_500)
        #expect(lines[2].value == "Third")
        #expect(lines[2].start == 123_456)
    }

    @Test func parseSynced_multipleTimestampsOnOneLine() {
        let lrc = "[00:10.00][00:20.00] Chorus"
        let lines = LRCParser.parseSynced(lrc)
        #expect(lines.count == 2)
        #expect(lines[0].start == 10_000)
        #expect(lines[1].start == 20_000)
        #expect(lines[0].value == "Chorus")
        #expect(lines[1].value == "Chorus")
    }

    @Test func parsePlain_splitsNonEmptyLines() {
        let lines = LRCParser.parsePlain("A\n\nB\n  C  ")
        #expect(lines.map(\.value) == ["A", "B", "C"])
        #expect(lines.allSatisfy { $0.start == nil })
    }

    @Test func parseEnhanced_plainLRC_staysLineOnly() {
        // No word stamps → line-level only, NO interpolation.
        let lrc = """
        [01:23.45] Hello world
        [01:25.00] Second line
        """
        let parsed = LRCParser.parseEnhanced(lrc)
        #expect(parsed.lines.count == 2)
        #expect(parsed.cueLines.isEmpty)
        #expect(parsed.lines[0].value == "Hello world")
        #expect(parsed.lines[0].start == 83_450)
    }

    @Test func parseEnhanced_ELRC_createsWordCues() {
        // ELRC: explicit word stamps → word-level karaoke cues.
        let lrc = "[01:23.45]<01:23.45>Hel<01:23.80>lo world<01:24.10>"
        let parsed = LRCParser.parseEnhanced(lrc)
        #expect(parsed.lines.count == 1)
        #expect(parsed.lines[0].value == "Hello world")
        #expect(parsed.lines[0].start == 83_450)

        #expect(parsed.cueLines.count == 1)
        let cue = parsed.cueLines[0]
        #expect(cue.cue.count == 2)
        #expect(cue.cue[0].value == "Hel")
        #expect(cue.cue[0].start == 83_450)
        #expect(cue.cue[0].end == 83_800)
        #expect(cue.cue[1].value == "lo world")
        #expect(cue.cue[1].start == 83_800)
        #expect(cue.cue[1].end == 84_100)
        // Trailing empty segment after last stamp is skipped.
    }

    @Test func parseEnhanced_ELRC_lastWordEndNil() {
        // Last word's end may be nil → filled by lookahead downstream.
        let lrc = "[00:10.00]<00:10.00>One<00:10.50>Two"
        let parsed = LRCParser.parseEnhanced(lrc)
        #expect(parsed.cueLines.count == 1)
        let cues = parsed.cueLines[0].cue
        #expect(cues.count == 2)
        #expect(cues[0].value == "One")
        #expect(cues[0].end == 10_500)
        #expect(cues[1].value == "Two")
        #expect(cues[1].end == nil)
    }
}
