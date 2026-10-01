// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation

/// Groups lyric lines for contextual machine translation, then splits the result
/// back onto the original line indices.
enum LyricTranslationBundler: Sendable {

    /// Contiguous non-empty lines translated together for natural phrasing.
    struct Bundle: Sendable, Equatable {
        /// Indices into the full lyrics array.
        let indices: [Int]
        /// Original line texts (same count as `indices`).
        let originalLines: [String]
        /// Joined source text sent to the translator.
        var joinedText: String {
            originalLines.joined(separator: "\n")
        }
    }

    /// Default window size — enough context without overloading Apple Translation.
    static let defaultBundleSize = 5

    /// Groups non-empty lines into windows of `bundleSize`. Blank / whitespace-only
    /// rows are skipped (callers keep those slots as the original empty string).
    static func makeBundles(from lyrics: [String], bundleSize: Int = defaultBundleSize) -> [Bundle] {
        let size = max(1, bundleSize)
        var bundles: [Bundle] = []
        var indices: [Int] = []
        var lines: [String] = []

        for (index, line) in lyrics.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            indices.append(index)
            lines.append(line)

            if indices.count == size {
                bundles.append(Bundle(indices: indices, originalLines: lines))
                indices = []
                lines = []
            }
        }

        if !indices.isEmpty {
            bundles.append(Bundle(indices: indices, originalLines: lines))
        }
        return bundles
    }

    /// Maps a translated block onto `originalLines.count` slots.
    ///
    /// 1. Prefer newline-aligned parts when the count matches.
    /// 2. Otherwise proportionally split by original line lengths, breaking near spaces.
    static func distribute(translated: String, onto originalLines: [String]) -> [String] {
        let count = originalLines.count
        guard count > 0 else { return [] }
        guard count > 1 else {
            let trimmed = translated.trimmingCharacters(in: .whitespacesAndNewlines)
            return [trimmed.isEmpty ? originalLines[0] : trimmed]
        }

        let normalized = translated
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let newlineParts = normalized.components(separatedBy: "\n")
        if newlineParts.count == count {
            return zip(newlineParts, originalLines).map { part, original in
                let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? original : trimmed
            }
        }

        // Collapse accidental blank lines from the MT output, then retry.
        let compactParts = newlineParts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if compactParts.count == count {
            return compactParts
        }

        let weights = originalLines.map { max($0.trimmingCharacters(in: .whitespacesAndNewlines).count, 1) }
        let body = compactParts.isEmpty
            ? normalized.trimmingCharacters(in: .whitespacesAndNewlines)
            : compactParts.joined(separator: " ")

        guard !body.isEmpty else { return originalLines }

        return proportionalSplit(body, weights: weights, fallback: originalLines)
    }

    /// Writes distributed parts back into a full lyrics-sized array (blank slots unchanged).
    static func apply(
        bundles: [Bundle],
        translatedBlocks: [String],
        into lyrics: [String]
    ) -> [String] {
        var result = lyrics
        for (bundle, block) in zip(bundles, translatedBlocks) {
            let parts = distribute(translated: block, onto: bundle.originalLines)
            for (offset, index) in bundle.indices.enumerated() {
                guard offset < parts.count, index < result.count else { continue }
                let part = parts[offset].trimmingCharacters(in: .whitespacesAndNewlines)
                result[index] = part.isEmpty ? lyrics[index] : part
            }
        }
        return result
    }

    // MARK: - Private

    private static func proportionalSplit(
        _ text: String,
        weights: [Int],
        fallback: [String]
    ) -> [String] {
        let totalWeight = max(weights.reduce(0, +), 1)
        let scalars = Array(text)
        guard !scalars.isEmpty else { return fallback }

        var parts: [String] = []
        var offset = 0

        for (index, weight) in weights.enumerated() {
            if index == weights.count - 1 {
                let slice = String(scalars[offset...]).trimmingCharacters(in: .whitespacesAndNewlines)
                parts.append(slice.isEmpty ? fallback[index] : slice)
                break
            }

            let ideal = Int((Double(scalars.count) * Double(weight) / Double(totalWeight)).rounded())
            let rawEnd = min(scalars.count, offset + max(ideal, 1))
            let cut = softBreakIndex(in: scalars, around: rawEnd, lowerBound: offset + 1)
            let slice = String(scalars[offset..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
            parts.append(slice.isEmpty ? fallback[index] : slice)
            offset = cut
            // Skip a single separator space/punctuation gap after the cut.
            while offset < scalars.count, scalars[offset].isWhitespace {
                offset += 1
            }
        }

        while parts.count < weights.count {
            parts.append(fallback[parts.count])
        }
        return Array(parts.prefix(weights.count))
    }

    /// Prefer breaking at whitespace near `around`, within a small window.
    private static func softBreakIndex(
        in scalars: [Character],
        around: Int,
        lowerBound: Int
    ) -> Int {
        let upper = min(scalars.count, around + 12)
        let lower = min(max(lowerBound, around - 12), upper)
        if lower >= upper { return min(max(lowerBound, around), scalars.count) }

        // Search backward first so earlier lines keep more of their share.
        let backEnd = min(around, upper)
        if lower < backEnd,
           let back = (lower..<backEnd).reversed().first(where: { scalars[$0].isWhitespace }) {
            return back
        }
        if around < upper,
           let forward = (around..<upper).first(where: { scalars[$0].isWhitespace }) {
            return forward
        }
        return min(max(lowerBound, around), scalars.count)
    }
}
