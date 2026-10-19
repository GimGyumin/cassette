// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI
import SwiftSonic
import Combine
import OSLog
import QuartzCore

extension LyricsViewModel {
    // MARK: - Background Translation Timing

    /// Returns the background translation text for the given display row index,
    /// but ONLY if the current playback time falls within the x-bg span timing.
    /// One flow insertion under the main line: chorus original + chorus translation.
    /// Apple Music renders this as a dynamic flow element below the translation line,
    /// NOT an overlay — it pushes the translation up and slides in from the top.
    struct LyricChorusBlock: Equatable, Sendable {
        let originalText: String
        let translationText: String
        let beginMs: Int
        let endMs: Int
        let isVisible: Bool
    }

    /// Returns the chorus (x-bg) block for a row when the current playback time
    /// is inside the x-bg span range.  Returns `nil` outside the range so no
    /// stale chorus text lingers after its window.
    /// - Note: `begin <= playbackTime < end` — strict end exclusive.
    ///
    /// Original chorus text sources (in priority order):
    /// 1. bgWords on this lead row (TTML x-bg span inside the lead paragraph)
    /// 2. Active secondary (backing) rows stacked under this lead
    /// Translation chorus: `line.backgroundTranslation` (TTML `<translation>` x-bg
    ///   or server parenthesized extraction), shown only when `areTranslationsVisible`.
    func activeChorusBlock(at index: Int) -> LyricChorusBlock? {
        guard displayRows.indices.contains(index) else { return nil }
        let row = displayRows[index]

        // Secondary-agent rows are handled by backing-overlay rendering.
        guard !row.isSecondaryAgent else { return nil }

        let lyric = translatedLyrics.indices.contains(index) ? translatedLyrics[index] : nil
        let rawBgTranslation = (lyric?.backgroundTranslation ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let bgWords = row.backgroundWords

        // ── Resolve original chorus text ──
        var originalText = ""
        // Source 1: bgWords on this row
        if !bgWords.isEmpty {
            originalText = Self.chorusDisplayText(from: bgWords)
        }
        // Source 2: active secondary rows stacked under this lead
        if originalText.isEmpty {
            let backingIndices = activeBackingOverlayIndices(underLead: index)
            let backingTexts = backingIndices.compactMap { idx -> String? in
                guard translatedLyrics.indices.contains(idx) else { return nil }
                let t = translatedLyrics[idx].originalText.trimmingCharacters(in: .whitespacesAndNewlines)
                // Strip parentheses: "(Change)" → "Change"
                let cleaned = t.replacingOccurrences(of: "(", with: "")
                             .replacingOccurrences(of: ")", with: "")
                             .trimmingCharacters(in: .whitespaces)
                return cleaned.isEmpty ? nil : cleaned
            }
            if !backingTexts.isEmpty {
                originalText = backingTexts.joined(separator: " ")
            }
        }

        // ── Translation text (gated by visibility) ──
        let translationText = areTranslationsVisible ? rawBgTranslation : ""

        // Need at least one of: original, translation
        guard !originalText.isEmpty || !translationText.isEmpty else { return nil }

        // ── Timing resolution ──
        // Use translation span → bgWords word timing → row timing → next lead
        let tBeginMs = lyric?.backgroundBegin.map { Int(($0 * 1000).rounded()) }
        let tEndMs = lyric?.backgroundEnd.map { Int(($0 * 1000).rounded()) }
        let wBeginMs = bgWords.compactMap({ $0.startMs > 0 ? $0.startMs : nil }).min()
        let wEndMs = bgWords.compactMap({ $0.endMs > 0 ? $0.endMs : nil }).max()

        let bgBegin = tBeginMs ?? wBeginMs ?? row.startMs ?? 0
        let bgEnd: Int
        if let te = tEndMs, te > bgBegin { bgEnd = te }
        else if let we = wEndMs, we > bgBegin { bgEnd = we }
        else if let re = row.endMs, re > bgBegin { bgEnd = re }
        else if let next = nextLeadStartMs(after: index), next > bgBegin { bgEnd = next }
        else { bgEnd = bgBegin + 2_000 }

        let currentMs = karaokePlaybackMs
        let visible = currentMs >= bgBegin && currentMs < bgEnd

        return LyricChorusBlock(
            originalText: originalText,
            translationText: translationText,
            beginMs: bgBegin,
            endMs: bgEnd,
            isVisible: visible
        )
    }

    /// Next non-secondary lead row start after the given index, or nil.
    private func nextLeadStartMs(after index: Int) -> Int? {
        guard index + 1 < displayRows.count else { return nil }
        for row in displayRows[(index + 1)...] {
            guard !row.isSecondaryAgent, let start = row.startMs else { continue }
            return start
        }
        return nil
    }

    /// Removes parenthesized phantom chorus from server translation text
    /// when the original body line has no x-bg backing (Apple data error).
    /// Handles both trailing and leading positions.
    /// Examples:
    ///   "난 변화를 만들 거야 (오, 예)" → "난 변화를 만들 거야"
    ///   "(예, 그 변화를 만들어) 정말 기분 좋을 거야" → "정말 기분 좋을 거야"
    /// Splits out parenthesized chorus text from server translation strings.
    /// Returns `main` (clean translation) and `chorus` (extracted parenthesized part).
    /// Example: "난 변화를 만들 거야 (오, 예)" → ("난 변화를 만들 거야", "오, 예")
    nonisolated static func extractParenthesizedChorus(from text: String) -> (main: String, chorus: String) {
        var main = text
        var chorusParts: [String] = []

        // Extract trailing "(...)"
        if let range = main.range(of: #"\s*\(([^)]*)\)\s*$"#, options: .regularExpression) {
            let raw = String(main[range])
            let cleaned = raw.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "()"))
            chorusParts.append(cleaned)
            main.removeSubrange(range)
        }

        // Extract leading "(...)"
        if let range = main.range(of: #"^\s*\(([^)]*)\)\s*"#, options: .regularExpression) {
            let raw = String(main[range])
            let cleaned = raw.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "()"))
            chorusParts.insert(cleaned, at: 0)
            main.removeSubrange(range)
        }

        return (main.trimmingCharacters(in: .whitespaces), chorusParts.joined(separator: " "))
    }

    /// Chorus is rendered as its own line, so remove presentation parentheses
    /// that may be preserved by TTML or generated by the translation engine.
    nonisolated static func normalizedChorusTranslation(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "()（）"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func stripParenthesizedSuffix(from text: String) -> String {
        var result = text
        // Strip trailing "(...)" with optional leading space.
        if let range = result.range(of: #"\s*\([^)]*\)\s*$"#, options: .regularExpression) {
            result = String(result[..<range.lowerBound])
        }
        // Strip leading "(...)" with optional trailing space.
        if let range = result.range(of: #"^\s*\([^)]*\)\s*"#, options: .regularExpression) {
            result = String(result[range.upperBound...])
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    nonisolated private static func chorusDisplayText(from words: [LyricDisplayWord]) -> String {
        words
            .map { word in
                word.text
                    .replacingOccurrences(of: "(", with: "")
                    .replacingOccurrences(of: ")", with: "")
            }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
