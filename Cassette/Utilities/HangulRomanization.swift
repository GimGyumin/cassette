// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation

/// Hangul ↔ Latin search support.
///
/// Siri/local search compares a query against catalog strings. Korean and Latin are
/// different scripts, so a raw substring match can never match a Hangul query to a
/// Latin title (or the reverse). `HangulRomanization` romanizes Hangul so both sides
/// of a comparison share a script, and folds case / diacritics / full-width glyphs.
nonisolated enum HangulRomanization {

    /// Romanizes Hangul syllables and compatibility jamo to Revised Romanization.
    /// Non-Hangul characters pass through unchanged.
    static func romanize(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for scalar in text.unicodeScalars {
            out += romanized(scalar) ?? String(scalar)
        }
        return out
    }

    /// Lowercased, diacritic/width-folded search tokens. Hangul-containing tokens also
    /// contribute their romanized form so cross-script queries match either script.
    static func searchTokens(_ text: String) -> [String] {
        let folded = text
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale.current)
            .lowercased()
        var tokens: [String] = []
        for word in folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            let token = String(word)
            if tokens.last != token { tokens.append(token) }
            if token.unicodeScalars.contains(where: { isHangul($0) }) {
                let roman = romanize(token).lowercased()
                if roman != token, !roman.isEmpty { tokens.append(roman) }
            }
        }
        return tokens
    }

    /// Whole-phrase comparison key (tokens concatenated).
    static func searchKey(_ text: String) -> String { searchTokens(text).joined() }

    // MARK: - Hangul syllable decomposition

    private static func romanized(_ scalar: Unicode.Scalar) -> String? {
        let value = scalar.value
        if (0xAC00...0xD7A3).contains(value) {
            let code = value - 0xAC00
            let initial = Int(code / 588)
            let medial = Int((code % 588) / 28)
            let final = Int(code % 28)
            return initialConsonants[initial] + vowels[medial] + finalConsonants[final]
        }
        if (0x3131...0x318E).contains(value) {
            return compatibilityJamo[value] ?? ""
        }
        return nil
    }

    private static func isHangul(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        return (0xAC00...0xD7A3).contains(value)
            || (0x1100...0x11FF).contains(value)
            || (0x3130...0x318F).contains(value)
    }

    // MARK: - Revised Romanization tables

    private static let initialConsonants = [
        "g", "kk", "n", "d", "tt", "r", "m", "b", "pp", "s",
        "ss", "", "j", "jj", "ch", "k", "t", "p", "h",
    ]

    private static let vowels = [
        "a", "ae", "ya", "yae", "eo", "e", "yeo", "ye", "o", "wa",
        "wae", "oe", "yo", "u", "wo", "we", "wi", "yu", "eu", "ui", "i",
    ]

    private static let finalConsonants = [
        "", "k", "k", "k", "n", "n", "n", "t", "l", "k",
        "m", "l", "l", "l", "p", "l", "m", "p", "p", "t",
        "t", "ng", "t", "t", "k", "t", "p", "t",
    ]

    private static let compatibilityJamo: [UInt32: String] = [
        0x3131: "g", 0x3132: "kk", 0x3134: "n", 0x3137: "d", 0x3138: "tt",
        0x3139: "r", 0x3141: "m", 0x3142: "b", 0x3143: "pp", 0x3145: "s",
        0x3146: "ss", 0x3147: "", 0x3148: "j", 0x3149: "jj", 0x314A: "ch",
        0x314B: "k", 0x314C: "t", 0x314D: "p", 0x314E: "h",
        0x314F: "a", 0x3150: "ae", 0x3151: "ya", 0x3152: "yae", 0x3153: "eo",
        0x3154: "e", 0x3155: "yeo", 0x3156: "ye", 0x3157: "o", 0x3158: "wa",
        0x3159: "wae", 0x315A: "oe", 0x315B: "yo", 0x315C: "u", 0x315D: "wo",
        0x315E: "we", 0x315F: "wi", 0x3160: "yu", 0x3161: "eu", 0x3162: "ui",
        0x3163: "i",
    ]
}
