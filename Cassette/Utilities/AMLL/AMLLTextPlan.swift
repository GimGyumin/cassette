// Swift adaptation of AMLL, AGPL-3.0-only; Copyright the AMLL contributors.
// Swift adaptation Copyright (C) 2026 Cassette contributors.
// Source: packages/core/src/utils/lyric-split-words.ts and lyric-player/dom/lyric-line.ts
// at 5fee356362353dbb24ce9bea3a62536478040de7. See Resources/Licenses/AMLL-AGPL-3.0.txt.
// Swift uses grapheme clusters rather than UTF-16 units, preserving composed characters.
import Foundation

nonisolated enum AMLLTextPlan {
    struct Word: Equatable, Sendable { let text: String; let start: Double; let end: Double }
    struct Token: Equatable, Sendable {
        let word: Word
        let group: Int
        var groupStart: Double
        var groupEnd: Double
        var emphasized = false
        var lastWord = false
    }
    static func prepare(_ words: [Word]) -> [Token] {
        var atoms: [Word] = []
        for word in words {
            var pieces: [String] = []
            for character in word.text {
                if let last = pieces.last, last.last?.isWhitespace == character.isWhitespace {
                    pieces[pieces.count - 1].append(character)
                } else { pieces.append(String(character)) }
            }
            let count = max(1, word.text.filter { !$0.isWhitespace }.count)
            let unit = max(0, word.end - word.start) / Double(count)
            var offset = 0
            for piece in pieces {
                if piece.allSatisfy(\.isWhitespace) {
                    let time = word.start + Double(offset) * unit
                    atoms.append(Word(text: piece, start: time, end: time))
                } else {
                    let fragments = AMLLGlyphStyle.isCJK(piece) ? piece.map(String.init) : [piece]
                    for fragment in fragments {
                        let start = word.start + Double(offset) * unit
                        offset += fragment.count
                        atoms.append(Word(text: fragment, start: start, end: word.start + Double(offset) * unit))
                    }
                }
            }
        }
        var groups: [[Word]] = [], pending: [Word] = []
        for atom in atoms {
            if atom.text.allSatisfy(\.isWhitespace) || AMLLGlyphStyle.isCJK(atom.text) {
                if !pending.isEmpty { groups.append(pending); pending = [] }
                groups.append([atom])
            } else { pending.append(atom) }
        }
        if !pending.isEmpty { groups.append(pending) }
        let last = groups.lastIndex { !$0.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return groups.enumerated().flatMap { index, group in
            let start = group.map(\.start).min() ?? 0, end = group.map(\.end).max() ?? 0
            let text = group.map(\.text).joined()
            let emphasized = group.contains { AMLLGlyphStyle.shouldEmphasize(text: $0.text, durationMs: $0.end - $0.start) }
                || (!AMLLGlyphStyle.isCJK(text) && AMLLGlyphStyle.shouldEmphasize(text: text, durationMs: end - start))
            return group.map { Token(word: $0, group: index, groupStart: start, groupEnd: end,
                                     emphasized: emphasized, lastWord: index == last) }
        }
    }
}
