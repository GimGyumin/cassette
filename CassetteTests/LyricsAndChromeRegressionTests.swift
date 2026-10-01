import Foundation
import SwiftUI
import Testing
@testable import Cassette

@Suite("Lyrics and chrome regressions")
@MainActor
struct LyricsAndChromeRegressionTests {
    @Test func koreanAndEnglishSyllablesFollowSourceSpaces() {
        let tokens = ["너 ", "와 ", "나 ", "heart", "break", "er", " tonight"]
        let line = LyricLine(begin: 0, end: 7, key: nil, agentId: nil,
                             words: tokens.enumerated().map {
                                 LyricWord(text: $0.element, begin: Double($0.offset), end: Double($0.offset + 1), role: .main)
                             }, documentOrder: 0, sourceLineIndex: 0)
        let restored = StructuredLyricsAdapter.restoringSpacing(in: line, source: "너와 나 heartbreaker tonight")
        #expect(restored.displayText == "너와 나 heartbreaker tonight")
        #expect(restored.words.map(\.text).joined() == "너와 나 heartbreaker tonight")
        #expect(restored.words.map(\.begin) == line.words.map(\.begin))
        #expect(restored.preservesSourceSpacing)
    }

    @Test func doesNotRewriteDifferentCueText() {
        let line = LyricLine(begin: 0, end: 1, key: nil, agentId: nil,
                             words: [LyricWord(text: "다른 가사", begin: 0, end: 1, role: .main)],
                             documentOrder: 0, sourceLineIndex: 0)
        #expect(StructuredLyricsAdapter.restoringSpacing(in: line, source: "원래 가사") == line)
    }

    @Test func translationSurvivesNewCacheInstanceForBothProviders() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let rows = [
            TranslatedLyric(time: 1, originalText: "Hello", translatedText: "안녕", isBlank: false),
            TranslatedLyric(time: 2, originalText: "(Oh)", translatedText: "", isBlank: false)
        ]
        let songID = String(repeating: "한글-song/", count: 100)
        for provider in [TranslationProvider.apple, .openAI] {
            TranslationCache(directory: directory).set(rows, songID: songID, sourceLang: "en", targetLang: "ko", provider: provider)
            let cache = TranslationCache(directory: directory)
            let restored = cache.get(songID: songID, sourceLang: "en", targetLang: "ko", provider: provider, originalLines: rows.map(\.originalText))
            #expect(restored == rows)
            #expect(cache.get(songID: songID, sourceLang: "en", targetLang: "ko", provider: provider, originalLines: ["Changed"]) == nil)
            #expect(cache.get(songID: songID, sourceLang: "en", targetLang: "ja", provider: provider, originalLines: rows.map(\.originalText)) == nil)
        }
    }

    @Test func departingPageCannotClearNewPageChrome() {
        let chrome = ChromeAppearance()
        let first = UUID(), second = UUID()
        chrome.appear(id: first, scheme: .dark)
        chrome.appear(id: second, scheme: .dark)
        chrome.disappear(id: first)
        #expect(chrome.overrideColorScheme == .dark)
        chrome.update(id: first, scheme: .light)
        #expect(chrome.overrideColorScheme == .dark)
        chrome.disappear(id: second)
        #expect(chrome.overrideColorScheme == nil)
    }

    @Test func blackOrWhiteAlwaysChoosesHigherContrast() {
        for color in [Color.black, .white, .red, .green, .blue, .gray, .yellow] {
            let luminance = CassetteColors.sRGBLuminance(of: color)!
            let white = CassetteColors.contrastRatio(luminance, 1)
            let black = CassetteColors.contrastRatio(luminance, 0)
            #expect(CassetteColors.prefersLightControl(on: color) == (white > black))
        }
    }
}
