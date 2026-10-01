// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Testing
import Foundation
@testable import Cassette

@Suite("LyricTime")
struct LyricTimeTests {
    @Test func parsesSecondsFractional() {
        #expect(LyricTime.parse("44.554") == 44.554)
    }

    @Test func parsesMinutesSeconds() {
        #expect(abs((LyricTime.parse("1:11.512") ?? 0) - 71.512) < 0.0001)
        #expect(abs((LyricTime.parse("01:11.512") ?? 0) - 71.512) < 0.0001)
    }
}

@Suite("AppleLyricTTMLParser")
struct AppleLyricTTMLParserTests {
    @Test func parsesSnippet_agentsRolesLeadingSilenceAndXBG() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/HeartbreakerSnippet.ttml")
        let data = try Data(contentsOf: url)
        let doc = try AppleLyricTTMLParser.parse(data: data)

        #expect(doc.language == "en")
        #expect(doc.timing == .word)
        #expect(abs(doc.leadingSilence - 0.260) < 0.0001)
        #expect(doc.songwriters == ["Michael Jackson"])
        #expect(doc.agents["v1"]?.name == "Michael Jackson")
        #expect(doc.agents["v2"] != nil)
        #expect(abs((doc.duration ?? 0) - 310.507) < 0.001)

        let lines = doc.allLines
        #expect(lines.count >= 2)

        let chorus = try #require(lines.first)
        #expect(chorus.agentId == "v1")
        #expect(chorus.mainWords.contains(where: { $0.text.contains("breaker") }))
        #expect(!chorus.backgroundWords.isEmpty)
        let allBackground = chorus.backgroundWords.allSatisfy { $0.role.isBackground }
        #expect(allBackground)
        #expect(chorus.backgroundWords.first?.text.contains("When") == true)

        let duet = try #require(lines.last)
        #expect(duet.agentId == "v2")
        #expect(duet.words.allSatisfy { !$0.role.isBackground })
    }

    @Test func preservesSpacesBetweenPrettyPrintedSpans() throws {
        // Newlines/indent between </span> and <span> must become a word space.
        let ttml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <tt xmlns="http://www.w3.org/ns/ttml"
            xmlns:itunes="http://music.apple.com/lyric-ttml-internal"
            xmlns:ttm="http://www.w3.org/ns/ttml#metadata"
            itunes:timing="Word" xml:lang="en">
          <body>
            <div>
              <p begin="1.0" end="3.0">
                <span begin="1.0" end="1.5">This</span>
                <span begin="1.5" end="2.5">one's</span>
                <span begin="2.5" end="3.0">mine</span>
              </p>
            </div>
          </body>
        </tt>
        """
        let doc = try AppleLyricTTMLParser.parse(string: ttml)
        let line = try #require(doc.allLines.first)
        #expect(line.displayText == "This one's mine")
        #expect(line.words.map(\.text) == ["This ", "one's ", "mine"]
            || line.words.map(\.text) == ["This ", "one's", " mine"]
            || line.words.reduce("") { $0 + $1.text }.contains("This one's"))
    }

    @Test func translationXBG_isSeparatedFromMainText() throws {
        // Requirement: <span ttm:role="x-bg"> inside <translation><text>
        // must NEVER be merged into the main translation string.
        let ttml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <tt xmlns="http://www.w3.org/ns/ttml"
            xmlns:itunes="http://music.apple.com/lyric-ttml-internal"
            xmlns:ttm="http://www.w3.org/ns/ttml#metadata"
            itunes:timing="Word" xml:lang="en">
          <body>
            <div>
              <p begin="1.0" end="3.0" itunes:key="L17">
                <span begin="1.0" end="3.0">I love you more than he</span>
                <span ttm:role="x-bg">
                  <span begin="2.0" end="3.0">(Take you anywhere)</span>
                </span>
              </p>
            </div>
          </body>
          <translations>
            <translation xml:lang="ko">
              <text for="L17">
                내가 저 사람보다 널 더 사랑해
                <span ttm:role="x-bg">(어디든 데려갈게)</span>
              </text>
            </translation>
          </translations>
        </tt>
        """
        let doc = try AppleLyricTTMLParser.parse(string: ttml)
        let translation = try #require(doc.translations["L17"])
        #expect(translation.main == "내가 저 사람보다 널 더 사랑해")
        #expect(translation.background == "(어디든 데려갈게)")

        // Aligned arrays keep the split too.
        let lines = doc.translatedLines
        let backgrounds = doc.backgroundTranslatedLines
        #expect(lines.count == 1)
        #expect(backgrounds.count == 1)
        #expect(lines[0] == "내가 저 사람보다 널 더 사랑해")
        #expect(backgrounds[0] == "(어디든 데려갈게)")
    }

    @Test func translationXBG_usesOwnBeginEndTiming() throws {
        // Requirement: use the x-bg span's OWN begin/end, not the main line's.
        let ttml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <tt xmlns="http://www.w3.org/ns/ttml"
            xmlns:itunes="http://music.apple.com/lyric-ttml-internal"
            xmlns:ttm="http://www.w3.org/ns/ttml#metadata"
            itunes:timing="Word" xml:lang="en">
          <body>
            <div>
              <p begin="10.0" end="20.0" itunes:key="L1">
                <span begin="10.0" end="20.0">main</span>
                <span ttm:role="x-bg">
                  <span begin="15.0" end="20.0">(Take you anywhere)</span>
                </span>
              </p>
            </div>
          </body>
          <translations>
            <translation xml:lang="ko">
              <text for="L1">
                메인
                <span ttm:role="x-bg">
                  <span begin="1:25.645" end="1:26.097">(Take</span>
                  <span begin="1:26.097" end="1:26.377">you</span>
                  <span begin="1:26.377" end="1:28.466">anywhere)</span>
                </span>
              </text>
            </translation>
          </translations>
        </tt>
        """
        let doc = try AppleLyricTTMLParser.parse(string: ttml)
        let translation = try #require(doc.translations["L1"])
        #expect(translation.main == "메인")
        #expect(translation.background == "(Take you anywhere)")
        // Aggregated span range from the translation's own timed sub-spans.
        let expectedBegin = 85.645
        let expectedEnd = 88.466
        #expect(abs((translation.backgroundBegin ?? 0) - expectedBegin) < 0.001)
        #expect(abs((translation.backgroundEnd ?? 0) - expectedEnd) < 0.001)
    }

    @Test func keepsGluedSyllableSpansWithoutInventingSpace() throws {
        let ttml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <tt xmlns="http://www.w3.org/ns/ttml" xmlns:itunes="http://music.apple.com/lyric-ttml-internal"
            xmlns:ttm="http://www.w3.org/ns/ttml#metadata" itunes:timing="Word" xml:lang="en">
          <body><div><p begin="1" end="2">
            <span begin="1.0" end="1.5">heart</span><span begin="1.5" end="2.0">breaker</span>
          </p></div></body>
        </tt>
        """
        let doc = try AppleLyricTTMLParser.parse(string: ttml)
        let line = try #require(doc.allLines.first)
        #expect(line.displayText == "heartbreaker")
    }

    @Test func activeWordsFilterByRole() throws {
        let ttml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <tt xmlns="http://www.w3.org/ns/ttml"
            xmlns:itunes="http://music.apple.com/lyric-ttml-internal"
            xmlns:ttm="http://www.w3.org/ns/ttml#metadata"
            itunes:timing="Word" xml:lang="en">
          <body>
            <div>
              <p begin="1.0" end="3.0" ttm:agent="v1">
                <span begin="1.0" end="2.5">lead</span>
                <span ttm:role="x-bg">
                  <span begin="2.0" end="3.0">(bg)</span>
                </span>
              </p>
            </div>
          </body>
        </tt>
        """
        let doc = try AppleLyricTTMLParser.parse(string: ttml)
        let line = try #require(doc.allLines.first)
        let at = 2.2
        let main = LyricTimelineQuery.activeWords(in: line, at: at, role: .main)
        let bg = LyricTimelineQuery.activeWords(in: line, at: at, role: .background)
        #expect(main.count == 1)
        #expect(bg.count == 1)
        #expect(LyricTimelineQuery.progress(for: main[0], at: at) > 0)
    }
}
