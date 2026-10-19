// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import Testing
@testable import Cassette

@MainActor
@Suite("Apple Intelligence translation prompts")
struct AppleIntelligencePromptTests {
    @Test func cacheSeparatesPromptsAndRetainsDefaultEntries() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = LyricsTranslationService(cache: TranslationCache(directory: directory))
        let rows = [TranslatedLyric(time: 0, originalText: "Hello", translatedText: "안녕", isBlank: false)]
        service.storeTranslation(rows, songID: "song", sourceLanguage: "en", targetLanguage: "ko",
                                 strategyPreference: .automatic, customPrompt: "Keep it poetic")
        let reopened = LyricsTranslationService(cache: TranslationCache(directory: directory))
        #expect(reopened.cachedTranslation(songID: "song", sourceLanguage: "en", targetLanguage: "ko",
            originalLines: ["Hello"], strategyPreference: .automatic, customPrompt: " Keep it poetic\n") == rows)
        for prompt in ["", "Use literal wording"] {
            #expect(reopened.cachedTranslation(songID: "song", sourceLanguage: "en", targetLanguage: "ko",
                originalLines: ["Hello"], strategyPreference: .automatic, customPrompt: prompt) == nil)
        }
        service.storeTranslation(rows, songID: "default", sourceLanguage: "en", targetLanguage: "ko",
                                 strategyPreference: .automatic)
        #expect(reopened.cachedTranslation(songID: "default", sourceLanguage: "en", targetLanguage: "ko",
            originalLines: ["Hello"], strategyPreference: .automatic, customPrompt: "\n ") == rows)
    }

    @Test func batchesBoundContextAndKeepLineOrder() throws {
        let sources = (0..<30).map { "\($0) " + String(repeating: "가", count: 300) }
        let batches = OnDeviceLyricTranslation.batches(sources)
        #expect(batches.flatMap { $0 } == sources)
        #expect(batches.allSatisfy { $0.count <= 6 && $0.reduce(0) { $0 + $1.count } <= 600 })
        let longLine = String(repeating: "긴 가사 한 줄입니다. ", count: 200)
        let parts = OnDeviceLyricTranslation.segments(longLine)
        #expect(parts.joined() == longLine)
        #expect(parts.allSatisfy { $0.count <= 600 })
    }

    @Test func cancelledRequestNeverStartsTheModel() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await AppleIntelligenceLyricsTranslator.shared.translate(
                lines: ["Hello"], targetLanguage: "ko", prompt: "Be natural"
            )
        }
        do { _ = try await task.value; Issue.record("Cancelled request unexpectedly succeeded") }
        catch is CancellationError {} catch { Issue.record("Expected cancellation, got \(error)") }
    }
}
