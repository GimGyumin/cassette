// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Testing
import Foundation
import SwiftSonic
@testable import Cassette

@Suite("LyricDocumentBuilder")
struct LyricDocumentBuilderTests {
    @Test func karaokeMergesBackgroundCueLineIntoLeadWords() {
        let structured = StructuredLyrics(
            lang: "en",
            synced: true,
            line: [Line(value: "heartbreaker (Oh)", start: 10_000)],
            agents: [
                LyricsAgent(id: "v1", role: "main"),
                LyricsAgent(id: "bg", role: "bg"),
            ],
            cueLine: [
                CueLine(
                    index: 0,
                    start: 10_000,
                    end: 12_000,
                    value: "heartbreaker",
                    agentId: "v1",
                    cue: [
                        LyricCue(start: 10_000, end: 12_000, value: "heartbreaker", byteStart: 0, byteEnd: 12),
                    ]
                ),
                CueLine(
                    index: 0,
                    start: 12_400,
                    end: 13_200,
                    value: "(Oh)",
                    agentId: "bg",
                    cue: [
                        LyricCue(start: 12_400, end: 13_200, value: "(Oh)", byteStart: 0, byteEnd: 4),
                    ]
                ),
            ]
        )
        let doc = LyricDocumentBuilder.fromStructured(structured)
        #expect(doc.timing == .word)
        #expect(doc.allLines.count == 1)
        let line = doc.allLines[0]
        #expect(line.mainWords.count == 1)
        #expect(line.backgroundWords.count == 1)
        #expect(line.backgroundWords[0].role == .background)

        let rows = LyricDisplayBuilder.rows(from: doc)
        #expect(rows.count == 1)
        #expect(rows[0].isSecondaryAgent == false)
        #expect(rows[0].backgroundWords.count == 1)
    }

    @Test func vocalPartTextRepairsMixedMissingSpacesBeforeBackgroundMerge() throws {
        let cases: [(String, [String])] = [
            ("If you want to know why", ["If you want to ", "know", "why"]),
            ("There’s a love that cannot lie", ["There's a love that ", "cannot", "lie"]),
            ("Love is strong", ["Love ", "is", "strong"])
        ]
        for (source, tokens) in cases {
            let cue = tokens.enumerated().map {
                LyricCue(start: $0.offset * 1000, end: ($0.offset + 1) * 1000,
                         value: $0.element, byteStart: 0, byteEnd: 0)
            }
            let structured = StructuredLyrics(lang: "en", synced: true,
                line: [Line(value: source + " (echo)", start: 0)],
                agents: [LyricsAgent(id: "v1", role: "main"), LyricsAgent(id: "bg", role: "bg")],
                cueLine: [CueLine(index: 0, start: 0, end: 3000, value: source, agentId: "v1", cue: cue),
                    CueLine(index: 0, start: 2000, end: 3000, value: "(echo)", agentId: "bg",
                        cue: [LyricCue(start: 2000, end: 3000, value: "(echo)", byteStart: 0, byteEnd: 5)])])
            let line = try #require(LyricDocumentBuilder.fromStructured(structured).allLines.first)
            #expect(line.displayText == source)
            #expect(line.mainWords.map(\.text).joined() == source)
            #expect(line.mainWords.map(\.begin) == [0, 1, 2])
            #expect(line.backgroundWords.map(\.text) == ["(echo)"])
            #expect(line.preservesSourceSpacing)
        }
    }

    @Test func vocalPartSpacingKeepsGluedSyllablesAndRejectsDifferentText() throws {
        let structured = StructuredLyrics(lang: "en", synced: true,
            line: [Line(value: "a different line (echo)", start: 0)],
            cueLine: [CueLine(index: 0, value: "heartbreaker", cue: [
                LyricCue(start: 0, end: 1000, value: "heart", byteStart: 0, byteEnd: 4),
                LyricCue(start: 1000, end: 2000, value: "break", byteStart: 5, byteEnd: 9),
                LyricCue(start: 2000, end: 3000, value: "er", byteStart: 10, byteEnd: 11)])])
        let row = try #require(LyricDisplayBuilder.rows(from: structured).first)
        #expect(row.text == "heartbreaker")
        #expect(LyricKaraokeSpacing.sourceTexts(row.words, secondary: false).joined() == "heartbreaker")
    }

    @Test func duetAgentsStaySeparateFullSizeRows() {
        let structured = StructuredLyrics(
            lang: "en",
            synced: true,
            line: [
                Line(value: "Hello", start: 1000),
                Line(value: "World", start: 2000),
            ],
            agents: [
                LyricsAgent(id: "v1", role: ""),
                LyricsAgent(id: "v2", role: ""),
            ],
            cueLine: [
                CueLine(
                    index: 0,
                    start: 1000,
                    value: "Hello",
                    agentId: "v1",
                    cue: [LyricCue(start: 1000, end: 1500, value: "Hello", byteStart: 0, byteEnd: 5)]
                ),
                CueLine(
                    index: 1,
                    start: 2000,
                    value: "World",
                    agentId: "v2",
                    cue: [LyricCue(start: 2000, end: 2500, value: "World", byteStart: 0, byteEnd: 5)]
                ),
            ]
        )
        let rows = LyricDisplayBuilder.rows(from: structured)
        #expect(rows.count == 2)
        #expect(rows[0].isSecondaryAgent == false)
        #expect(rows[1].isSecondaryAgent == false)
        #expect(rows[0].speakerSide == .leading)
        #expect(rows[1].speakerSide == .trailing)
    }

    @Test func lineSyncedAndPlainStillWork() {
        let synced = StructuredLyrics(
            lang: "en",
            synced: true,
            line: [
                Line(value: "One", start: 0),
                Line(value: "Two", start: 2000),
            ]
        )
        let syncedDoc = LyricDocumentBuilder.fromStructured(synced)
        #expect(syncedDoc.timing == .line)
        #expect(LyricDisplayBuilder.rows(from: syncedDoc).count == 2)

        let plain = StructuredLyrics(
            lang: "en",
            synced: false,
            line: [Line(value: "Only text"), Line(value: "More text")]
        )
        let plainDoc = LyricDocumentBuilder.fromStructured(plain)
        #expect(plainDoc.timing == .none)
        #expect(LyricDisplayBuilder.rows(from: plainDoc).count == 2)
    }

    @Test func koreanExplicitSpacesArePreserved() throws {
        // XML text owns word boundaries. Do not delete explicit spaces based on script.
        let ttml = """
        <tt xmlns="http://www.w3.org/ns/ttml" xml:lang="ko">
          <body>
            <div>
              <p begin="1.0" end="2.0">
                <span begin="1.0" end="1.4">안 </span>
                <span begin="1.4" end="1.8">녕 </span>
                <span begin="1.8" end="2.0">하세요</span>
              </p>
            </div>
          </body>
        </tt>
        """
        let doc = try AppleLyricTTMLParser.parse(string: ttml)
        let text = doc.allLines.first?.displayText ?? ""
        #expect(text == "안 녕 하세요")
    }

    @Test func prefersTTMLOverStructured() throws {
        let ttml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <tt xmlns="http://www.w3.org/ns/ttml" xmlns:itunes="http://music.apple.com/lyric-ttml-internal"
            xmlns:ttm="http://www.w3.org/ns/ttml#metadata" itunes:timing="Word" xml:lang="ko">
          <body><div><p begin="1.0" end="2.0"><span begin="1.0" end="2.0">안녕</span></p></div></body>
        </tt>
        """
        let data = try #require(ttml.data(using: .utf8))
        let structured = StructuredLyrics(
            lang: "en",
            synced: true,
            line: [Line(value: "ignored", start: 0)]
        )
        let doc = try #require(LyricDocumentBuilder.build(preferringTTML: data, structured: structured))
        #expect(doc.language == "ko")
        #expect(doc.allLines.first?.displayText.contains("안녕") == true)
    }
}
