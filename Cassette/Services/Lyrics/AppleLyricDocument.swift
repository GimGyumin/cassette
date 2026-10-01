// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation

// MARK: - Timing

nonisolated enum LyricTimingMode: String, Equatable, Sendable {
    case word
    case line
    case none
}

nonisolated enum LyricTime {
    /// Parses Apple TTML times: `44.554`, `1:11.512`, `01:11.512`.
    static func parse(_ string: String) -> TimeInterval? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        for (suffix, multiplier) in [("ms", 0.001), ("h", 3600.0), ("m", 60.0), ("s", 1.0)] {
            if trimmed.hasSuffix(suffix) {
                guard let value = Double(trimmed.dropLast(suffix.count)), value.isFinite, value >= 0 else { return nil }
                let seconds = value * multiplier
                return seconds.isFinite && seconds < Double(Int.max) / 2000 ? seconds : nil
            }
        }
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.allSatisfy({ Double($0).map { $0.isFinite && $0 >= 0 } == true }) else { return nil }
        let value: Double
        switch parts.count {
        case 1:
            guard let seconds = Double(parts[0]) else { return nil }
            value = seconds
        case 2:
            guard let minutes = Double(parts[0]), let seconds = Double(parts[1]) else { return nil }
            value = minutes * 60 + seconds
        case 3:
            guard let hours = Double(parts[0]),
                  let minutes = Double(parts[1]),
                  let seconds = Double(parts[2]) else { return nil }
            value = hours * 3600 + minutes * 60 + seconds
        default:
            return nil
        }
        return value.isFinite && value < Double(Int.max) / 2000 ? value : nil
    }

    static func seconds(fromMilliseconds ms: Int) -> TimeInterval {
        TimeInterval(ms) / 1000
    }

    static func milliseconds(fromSeconds seconds: TimeInterval) -> Int {
        guard seconds.isFinite, abs(seconds) < Double(Int.max) / 2000 else { return 0 }
        return Int((seconds * 1000).rounded())
    }
}

// MARK: - Role

nonisolated enum LyricRole: Equatable, Sendable, Hashable {
    case main
    case background
    case custom(String)

    static func map(_ raw: String?) -> LyricRole {
        guard let raw, !raw.isEmpty else { return .main }
        let lower = raw.lowercased()
        if lower == "x-bg" || lower == "bg" || lower == "background" || lower.hasSuffix("-bg") {
            return .background
        }
        if lower == "main" || lower == "voice" { return .main }
        return .custom(raw)
    }

    var isBackground: Bool {
        if case .background = self { return true }
        return false
    }
}

// MARK: - Document model

nonisolated struct LyricAgent: Equatable, Sendable, Hashable {
    let id: String
    let name: String?
    let type: String?
    /// Wire / TTML role string when present (`main`, `bg`, `voice`, …).
    let role: String?
}

nonisolated struct LyricWord: Equatable, Sendable, Hashable {
    let text: String
    let begin: TimeInterval
    let end: TimeInterval
    let role: LyricRole
    var agentId: String? = nil
    var ruby: String? = nil
}

nonisolated struct LyricLine: Equatable, Sendable, Hashable {
    let begin: TimeInterval?
    let end: TimeInterval?
    let key: String?
    let agentId: String?
    let words: [LyricWord]
    /// Stable document order (TTML / source order). Never reorder for rendering.
    let documentOrder: Int
    /// Index into OpenSubsonic `line[]` when adapted from JSON; `nil` for pure TTML.
    let sourceLineIndex: Int?
    var preservesSourceSpacing: Bool = false
    var preservesSourceTiming: Bool = false

    var mainWords: [LyricWord] { words.filter { !$0.role.isBackground } }
    var backgroundWords: [LyricWord] { words.filter(\.role.isBackground) }
    var isBackgroundOnly: Bool {
        !words.isEmpty && words.allSatisfy(\.role.isBackground)
    }

    var displayText: String {
        let texts = mainWords.map(\.text)
        if preservesSourceSpacing {
            return texts.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Without an authoritative full line, preserve explicit spaces and do not
        // invent separators between CJK syllables or mixed-script fragments.
        let isCJK = texts.contains { text in
            text.unicodeScalars.contains { scalar in
                switch scalar.value {
                case 0xAC00...0xD7AF,   // Hangul Syllables
                     0x1100...0x11FF,   // Hangul Jamo
                     0x3130...0x318F,   // Hangul Compatibility Jamo
                     0x4E00...0x9FFF,   // CJK Unified Ideographs
                     0x3040...0x30FF,   // Hiragana + Katakana
                     0x3400...0x4DBF,   // CJK Extension A
                     0xF900...0xFAFF,   // CJK Compatibility Ideographs
                     0x2E80...0x2EFF:   // CJK Radicals Supplement
                    return true
                default: return false
                }
            }
        }
        if isCJK {
            let joined = texts.joined()
            return joined
        }
        // TTML words mostly carry their own trailing spaces ("Your "), except the last word
        // in a line, glued syllables ("heart"+"breaker"), and background spans.
        // Explicit whitespace takes precedence over fallback word separators.
        let needsSpaceSeparator = !texts.contains { $0.contains(where: \.isWhitespace) }
        let joined = texts.joined(separator: needsSpaceSeparator ? " " : "")
        return joined.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var resolvedBegin: TimeInterval? {
        begin ?? words.map(\.begin).min()
    }

    var resolvedEnd: TimeInterval? {
        end ?? words.compactMap(\.end).max()
    }
}

nonisolated struct LyricSection: Equatable, Sendable, Hashable {
    let begin: TimeInterval?
    let end: TimeInterval?
    let songPart: String?
    let lines: [LyricLine]
}

/// One `<translation><text for="key">` value with x-bg separation done structurally
/// at parse time (SAX level), so the main text and chorus/backing text never merge.
nonisolated struct LyricTranslation: Equatable, Sendable, Hashable {
    /// Main translation text — x-bg spans are **never** appended to this.
    let main: String
    /// Chorus / backing translation pulled from `<span ttm:role="x-bg">`.
    let background: String
    /// Time range of the x-bg span inside the translation (may be nil when untimed).
    /// This is the translation's own timing — NOT the main line's begin/end.
    let backgroundBegin: TimeInterval?
    let backgroundEnd: TimeInterval?
    /// Apple TTML marks machine-generated translation layers with this attribute.
    let automaticallyCreated: Bool

    init(
        main: String,
        background: String,
        backgroundBegin: TimeInterval?,
        backgroundEnd: TimeInterval?,
        automaticallyCreated: Bool = false
    ) {
        self.main = main
        self.background = background
        self.backgroundBegin = backgroundBegin
        self.backgroundEnd = backgroundEnd
        self.automaticallyCreated = automaticallyCreated
    }
}

nonisolated struct LyricTransliteration: Equatable, Sendable, Hashable {
    let words: [LyricWord]
    let automaticallyCreated: Bool
    var main: String { words.filter { !$0.role.isBackground }.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines) }
    var background: String { words.filter(\.role.isBackground).map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines) }
}

nonisolated struct LyricDocument: Equatable, Sendable {
    let language: String?
    let timing: LyricTimingMode
    let duration: TimeInterval?
    let leadingSilence: TimeInterval
    /// Apple Music `<audio lyricOffset="..."/>` — added to playback time before
    /// comparing against TTML begin/end (`displayTime = playerTime + lyricOffset`).
    /// Negative values shift lyrics earlier; positive shift later.
    let lyricOffset: TimeInterval
    let agents: [String: LyricAgent]
    let songwriters: [String]
    let sections: [LyricSection]
    /// TTML `<translation xml:lang>` attribute — language code of the embedded translation.
    var translationLanguage: String? = nil
    /// TTML `<text for="key">` pairs parsed from `<translations>`, keyed by the
    /// referenced `<p itunes:key="...">`. Main text and x-bg are kept separate.
    var translations: [String: LyricTranslation] = [:]
    var translationsByLanguage: [String: [String: LyricTranslation]] = [:]
    var transliterationsByLanguage: [String: [String: LyricTransliteration]] = [:]

    func pronunciation(for key: String) -> LyricTransliteration? {
        let languages = transliterationsByLanguage.keys.sorted()
        let preferred = languages.first { $0.lowercased().contains("latn") } ?? languages.first
        return preferred.flatMap { transliterationsByLanguage[$0]?[key] }
    }

    mutating func selectTranslation(preferredLanguages: [String]) {
        let available = translationsByLanguage.keys.sorted()
        for language in preferredLanguages {
            let normalized = language.replacingOccurrences(of: "_", with: "-").lowercased()
            let match = available.first { $0.lowercased() == normalized }
                ?? available.first { $0.lowercased().split(separator: "-").first == normalized.split(separator: "-").first }
            if let match {
                translationLanguage = match
                translations = translationsByLanguage[match] ?? [:]
                return
            }
        }
    }

    /// Flat lines in document order.
    var allLines: [LyricLine] {
        sections.flatMap(\.lines).sorted { $0.documentOrder < $1.documentOrder }
    }

    /// Main translation strings aligned with `allLines` order (empty where no translation exists).
    /// x-bg content is never merged into these strings.
    var translatedLines: [String] {
        guard !translations.isEmpty else { return [] }
        return allLines.map { line in
            guard let key = line.key, let translated = translations[key] else { return "" }
            return translated.main.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Keys of body lines whose words contain at least one x-bg role span.
    /// Used downstream to suppress phantom translation x-bg when the
    /// original English lyric has no backing vocal (Apple data error).
    var bodyLineKeysWithBackground: Set<String> {
        var keys: Set<String> = []
        for section in sections {
            for line in section.lines {
                if let key = line.key, line.words.contains(where: { $0.role.isBackground }) {
                    keys.insert(key)
                }
            }
        }
        return keys
    }

    /// Background / chorus translation strings aligned with `allLines`.
    var backgroundTranslatedLines: [String] {
        guard !translations.isEmpty else { return [] }
        return allLines.map { line in
            guard let key = line.key, let translated = translations[key] else { return "" }
            return translated.background.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Legacy fallback splitter used only for raw strings that still contain tags
    /// (e.g. tests / non-SAX call sites). The parser now separates x-bg structurally.
    nonisolated static func splitTranslation(_ text: String) -> (main: String, background: String) {
        var main = text
        var bgParts: [String] = []

        // Extract all x-bg span contents using NSRegularExpression (handles multiple spans).
        let pattern = "<span[^>]*ttm:role=\"x-bg\"[^>]*>(.*?)</span>"
        if let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) {
            let nsString = text as NSString
            let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsString.length))

            // Process in reverse order so removal indices stay valid.
            for match in matches.reversed() {
                if match.numberOfRanges >= 2 {
                    let bgRange = match.range(at: 1)
                    let bgText = nsString.substring(with: bgRange)
                    bgParts.insert(bgText, at: 0)
                }
                main = (main as NSString).replacingCharacters(in: match.range, with: "")
            }
        }

        let bg = bgParts.joined(separator: " ")

        // Strip remaining span tags from main.
        main = main
            .replacingOccurrences(of: "<span[^>]*>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "</span>", with: "")
        return (main, bg)
    }

    var primaryAgentId: String? {
        let counts = allLines.reduce(into: [String: Int]()) { partial, line in
            guard let id = line.agentId, !line.isBackgroundOnly else { return }
            partial[id, default: 0] += 1
        }
        if let explicit = agents.values.first(where: { ($0.role ?? "").lowercased() == "main" })?.id,
           counts[explicit] != nil {
            return explicit
        }
        return counts.max { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value < rhs.value }
            return lhs.key > rhs.key
        }?.key
    }
}

// MARK: - Timeline query

nonisolated enum LyricTimelineQuery {
    static func activeLines(in document: LyricDocument, at time: TimeInterval) -> [LyricLine] {
        document.allLines.filter { line in
            guard let begin = line.resolvedBegin else { return false }
            let end = line.resolvedEnd ?? begin
            return time >= begin && time < end
        }
    }

    static func activeWords(
        in line: LyricLine,
        at time: TimeInterval,
        role: LyricRole? = nil
    ) -> [LyricWord] {
        line.words.filter { word in
            if let role {
                switch (role, word.role) {
                case (.main, .main), (.main, .custom): break
                case (.background, .background): break
                case (.custom(let a), .custom(let b)) where a == b: break
                default: return false
                }
            }
            return time >= word.begin && time < word.end
        }
    }

    static func progress(for word: LyricWord, at time: TimeInterval) -> Double {
        guard time >= word.begin else { return 0 }
        guard time <= word.end else { return 1 }
        let span = max(word.end - word.begin, 0.001)
        return min(1, max(0, (time - word.begin) / span))
    }

    static func currentWordIndex(in words: [LyricWord], at time: TimeInterval) -> Int? {
        var found: Int?
        for (index, word) in words.enumerated() {
            if word.begin <= time {
                found = index
            } else {
                break
            }
        }
        return found
    }
}
