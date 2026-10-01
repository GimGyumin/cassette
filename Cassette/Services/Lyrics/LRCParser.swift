// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import SwiftSonic

/// Parses LRC / ELRC timed lyrics and plain lyric text into OpenSubsonic models.
///
/// - Plain LRC: `[01:23.45]Hello world` → line-level timing only.
///   Per the spec, NO word interpolation is ever performed for lines without word stamps.
/// - ELRC: `[01:23.45]<01:23.45>Hel<01:23.80>lo` → word-level timing is preserved
///   as `CueLine` karaoke cues. Only explicit `<mm:ss.xx>` stamps are used.
nonisolated enum LRCParser {
    /// `[mm:ss.xx]` or `[mm:ss.xxx]` — may appear multiple times before the text.
    private static let timestampRegex = try! NSRegularExpression(
        pattern: #"\[(\d{1,2}):(\d{2})(?:\.(\d{1,3}))?\]"#
    )
    /// ELRC word stamps: `<mm:ss.xx>` or `<mm:ss.xxx>` inside the line body.
    private static let wordStampRegex = try! NSRegularExpression(
        pattern: #"<(\d{1,2}):(\d{2})(?:\.(\d{1,3}))?>"#
    )

    /// Parsed ELRC result: line-level entries plus optional word-level karaoke cues.
    struct EnhancedResult {
        let lines: [Line]
        let cueLines: [CueLine]
    }

    static func parseSynced(_ lrc: String) -> [Line] {
        parseEnhanced(lrc).lines
    }

    /// Parses LRC / ELRC. Lines without `<ts>` word stamps produce line-only entries
    /// (NO interpolation — each line stays a single token). Lines with word stamps
    /// produce both `Line` and word-level `CueLine` karaoke cues.
    static func parseEnhanced(_ lrc: String) -> EnhancedResult {
        var lines: [Line] = []
        var cueLines: [CueLine] = []
        var lineOrder = 0

        for raw in lrc.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            let ns = line as NSString
            let full = NSRange(location: 0, length: ns.length)
            let matches = timestampRegex.matches(in: line, range: full)
            guard !matches.isEmpty else { continue }

            let last = matches[matches.count - 1]
            let bodyStart = last.range.location + last.range.length
            let body = ns.substring(from: bodyStart)
            let bodyNS = body as NSString
            let wordMatches = wordStampRegex.matches(
                in: body,
                range: NSRange(location: 0, length: bodyNS.length)
            )

            // ── Plain LRC line (no word stamps) — line unit only, no interpolation.
            if wordMatches.isEmpty {
                let text = body.trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { continue }
                for match in matches {
                    guard let start = milliseconds(from: match, in: ns) else { continue }
                    lines.append(Line(value: text, start: start))
                }
                continue
            }

            // ── ELRC line — explicit word stamps are the ONLY timing used.
            let strippedText = body
                .replacingOccurrences(
                    of: #"<\d{1,2}:\d{2}(?:\.\d{1,3})?>"#,
                    with: "",
                    options: .regularExpression
                )
                .trimmingCharacters(in: .whitespaces)

            var cues: [LyricCue] = []
            var byte = 0
            for (i, wordMatch) in wordMatches.enumerated() {
                guard let start = milliseconds(from: wordMatch, in: bodyNS) else { continue }
                let segStart = wordMatch.range.location + wordMatch.range.length
                let segEnd = i + 1 < wordMatches.count
                    ? wordMatches[i + 1].range.location
                    : bodyNS.length
                let segText = bodyNS
                    .substring(with: NSRange(location: segStart, length: segEnd - segStart))
                    .trimmingCharacters(in: .whitespaces)
                guard !segText.isEmpty else { continue }

                let end = i + 1 < wordMatches.count
                    ? milliseconds(from: wordMatches[i + 1], in: bodyNS)
                    : nil // last word end = line end (filled by lookahead downstream)
                let utf8 = segText.utf8.count
                cues.append(
                    LyricCue(
                        start: start,
                        end: end,
                        value: segText,
                        byteStart: byte,
                        byteEnd: byte + max(utf8 - 1, 0)
                    )
                )
                byte += utf8
            }

            guard !cues.isEmpty else { continue }

            for match in matches {
                guard let start = milliseconds(from: match, in: ns) else { continue }
                lines.append(Line(value: strippedText, start: start))
                cueLines.append(
                    CueLine(
                        index: lineOrder,
                        start: start,
                        end: cues.last?.end ?? start,
                        value: strippedText,
                        agentId: nil,
                        cue: cues
                    )
                )
            }
            lineOrder += 1
        }

        let sortedLines = lines.sorted { ($0.start ?? 0) < ($1.start ?? 0) }
        return EnhancedResult(lines: sortedLines, cueLines: cueLines)
    }

    static func parsePlain(_ text: String) -> [Line] {
        text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { Line(value: $0) }
    }

    private static func milliseconds(from match: NSTextCheckingResult, in ns: NSString) -> Int? {
        guard match.numberOfRanges >= 3,
              let min = Int(ns.substring(with: match.range(at: 1))),
              let sec = Int(ns.substring(with: match.range(at: 2))) else { return nil }
        var ms = 0
        if match.numberOfRanges >= 4, match.range(at: 3).location != NSNotFound {
            let frac = ns.substring(with: match.range(at: 3))
            if frac.count <= 2 {
                ms = (Int(frac) ?? 0) * (frac.count == 1 ? 100 : 10)
            } else {
                ms = Int(frac.prefix(3)) ?? 0
            }
        }
        return (min * 60 + sec) * 1000 + ms
    }
}
