// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Testing
import Foundation
@testable import Cassette

@Suite("HangulRomanization")
struct HangulRomanizationTests {
    @Test("romanizes Hangul syllables to Revised Romanization")
    func romanizesSyllables() {
        #expect(HangulRomanization.romanize("빌리진") == "bilrijin")
        #expect(HangulRomanization.romanize("아이유") == "aiyu")
        #expect(HangulRomanization.romanize("안녕") == "annyeong")
        #expect(HangulRomanization.romanize("한글") == "hangeul")
    }

    @Test("searchTokens emits the romanized form alongside Hangul")
    func searchTokensIncludeRomanization() {
        let tokens = HangulRomanization.searchTokens("아이유")
        #expect(tokens.contains("아이유"))
        #expect(tokens.contains("aiyu"))
    }

    @Test("folds case, diacritics and full-width glyphs")
    func foldsCaseDiacriticsWidth() {
        let tokens = HangulRomanization.searchTokens("BILLIE JEAN")
        #expect(tokens.contains("billie"))
        #expect(tokens.contains("jean"))
    }
}
