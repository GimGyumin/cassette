// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.

import SwiftUI
import SwiftSonic

/// Apple Music–style word-by-word TTML karaoke with left-to-right mask fill.
struct LyricWordKaraokeLine: View {
    var words: [LyricDisplayWord] = []
    var cueLine: CueLine? = nil
    let adjustedMs: Int
    var nextLineStartMs: Int? = nil
    let fontSize: CGFloat
    var isSecondary: Bool = false
    var textAlignment: TextAlignment = .leading
    var reduceMotion: Bool = false

    private var resolved: [LyricDisplayWord] {
        if !words.isEmpty { return words }
        guard let cl = cueLine else { return [] }
        return Self.displayWords(from: cl)
    }
    private var mw: [LyricDisplayWord] {
        let m = resolved.filter { !$0.isBackground }
        if m.isEmpty, isSecondary { return resolved }
        return m
    }
    var body: some View {
        PreparedLyricText(words: mw, fontSize: fontSize, secondary: isSecondary)
            .equatable()
            .textRenderer(LyricGlyphRenderer(timeMs: Double(adjustedMs), fontSize: fontSize,
                secondary: isSecondary, motion: !reduceMotion))
            .multilineTextAlignment(textAlignment)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: textAlignment == .trailing ? .trailing : textAlignment == .center ? .center : .leading)
    }

    // helpers
    private static func displayWords(from cl: CueLine) -> [LyricDisplayWord] {
        var r: [LyricDisplayWord] = []; var ip = false
        for c in cl.cue {
            let t = c.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !ip, t.contains("(") { ip = true }
            r.append(LyricDisplayWord(text: c.value, startMs: c.start, endMs: c.end ?? c.start, role: ip ? .background : .main))
            if ip, t.contains(")") { ip = false }
        }
        return r
    }
}

/// Timing is an attribute of text, not a separate layout box. Native paragraph
/// shaping preserves delimiters, kerning, connected scripts and balanced wrapping.
private struct LyricTokenTiming: TextAttribute {
    let id: Int
    let start: Double
    let end: Double
    let emphasized: Bool
    let lastWord: Bool
    let group: Int
    let groupStart: Double
    let groupEnd: Double
}

private struct PreparedLyricText: View, Equatable {
    let words: [LyricDisplayWord]
    let fontSize: CGFloat
    let secondary: Bool

    private var text: Text {
        let strings = LyricKaraokeSpacing.sourceTexts(words, secondary: secondary)
        let input = words.enumerated().map { index, word in
            let end = word.endMs > word.startMs ? word.endMs
                : max(word.startMs + 1, words[safe: index + 1]?.startMs ?? word.startMs + 280)
            return AMLLTextPlan.Word(text: strings[index], start: Double(word.startMs), end: Double(end))
        }
        return AMLLTextPlan.prepare(input).enumerated().reduce(Text(verbatim: "")) { result, pair in
            let (index, token) = pair
            let piece = Text(verbatim: token.word.text).customAttribute(
                LyricTokenTiming(id: index, start: token.word.start, end: token.word.end,
                    emphasized: token.emphasized, lastWord: token.lastWord, group: token.group,
                    groupStart: token.groupStart, groupEnd: token.groupEnd))
            return Text("\(result)\(piece)")
        }
    }

    var body: some View {
        text.font(.system(size: secondary ? fontSize * 0.92 : fontSize, weight: secondary ? .semibold : .bold))
            .foregroundStyle(.white)
    }
}

struct LyricGlyphRenderer: TextRenderer {
    let timeMs: Double
    let fontSize: CGFloat
    let secondary: Bool
    let motion: Bool

    // Horizontal display padding also widens SwiftUI's drawing layout without
    // widening the measured paragraph. Center/trailing alignment then shifts ink
    // beyond its row and may even wrap differently from the measured text.
    // The row already supplies horizontal breathing room; only extend vertically
    // for glyph lift/glow so every alignment uses the same paragraph width.
    var displayPadding: EdgeInsets { EdgeInsets(top: 14, leading: 0, bottom: 10, trailing: 0) }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        // One token can wrap or form multiple shaping runs. Its highlight still
        // progresses once over its complete typographic length, never per visual line.
        var widths: [Int: CGFloat] = [:]
        var glyphCounts: [Int: Int] = [:]
        for line in layout {
            for run in line {
                guard let timing = run[LyricTokenTiming.self] else { continue }
                widths[timing.id, default: 0] += run.typographicBounds.rect.width
                glyphCounts[timing.group, default: 0] += run.count
            }
        }
        var preceding: [Int: CGFloat] = [:]
        var glyphOffsets: [Int: Int] = [:]
        let feather = max(1, fontSize * 0.5)
        for line in layout {
            for run in line {
                guard let timing = run[LyricTokenTiming.self] else { context.draw(run); continue }
                let bounds = run.typographicBounds.rect
                let width = max(1, widths[timing.id, default: bounds.width])
                let prefix = preceding[timing.id, default: 0]
                preceding[timing.id, default: 0] += bounds.width
                let edge = bounds.minX - prefix + AMLLWordMask.edge(timeMs: timeMs,
                    startMs: timing.start, endMs: timing.end, width: width, fadeWidth: feather)
                for slice in run {
                    let rect = slice.typographicBounds.rect
                    let character = glyphOffsets[timing.group, default: 0]
                    glyphOffsets[timing.group, default: 0] += 1
                    let phase = AMLLGlyphStyle.sample(timeMs: timeMs, startMs: timing.start, endMs: timing.end,
                        fontSize: fontSize, character: character, count: glyphCounts[timing.group, default: 1],
                        emphasized: timing.emphasized, lastWord: timing.lastWord, background: secondary, motion: motion,
                        emphasisStartMs: timing.groupStart, emphasisEndMs: timing.groupEnd)
                    var glyph = context
                    glyph.translateBy(x: rect.midX + phase.shiftX, y: rect.maxY - phase.lift)
                    glyph.scaleBy(x: phase.scale, y: phase.scale)
                    glyph.translateBy(x: -rect.midX, y: -rect.maxY)
                    var dim = glyph
                    dim.opacity = 0.4
                    dim.draw(slice)
                    guard edge + feather / 2 > rect.minX else { continue }
                    var bright = glyph
                    if edge - feather / 2 < rect.maxX {
                        bright.clipToLayer { mask in
                            mask.fill(Path(bounds.insetBy(dx: -8, dy: -10)), with: .linearGradient(
                                Gradient(colors: [.white, .clear]),
                                startPoint: CGPoint(x: edge - feather / 2, y: 0),
                                endPoint: CGPoint(x: edge + feather / 2, y: 0)))
                        }
                    }
                    bright.opacity = secondary ? 0.84 : 1
                    if phase.glow > 0.01 {
                        bright.addFilter(.shadow(color: .white.opacity(phase.glow), radius: phase.glowRadius))
                    }
                    bright.draw(slice)
                }
            }
        }
    }
}

/// Preserve source separators in one native text paragraph. A delimiter-only span
/// remains text, so it cannot collapse to a zero-width SwiftUI layout child.
nonisolated enum LyricKaraokeSpacing {
    static func displayTexts(_ words: [LyricDisplayWord], secondary: Bool) -> [String] {
        sourceTexts(words, secondary: secondary).map(visibleText)
    }

    static func sourceTexts(_ words: [LyricDisplayWord], secondary: Bool) -> [String] {
        let hasSourceBoundaries = words.contains { isCJK($0.text) || $0.text.contains(where: \.isWhitespace) }
        return words.enumerated().map { index, word in
            let raw = secondary ? word.text.replacingOccurrences(of: "(", with: "").replacingOccurrences(of: ")", with: "") : word.text
            let text = word.preservesSourceSpacing || hasSourceBoundaries || index == words.count - 1 || raw.hasSuffix(" ")
                ? raw : raw + " "
            return text
        }
    }

    private static func isCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0xAC00...0xD7AF,   // Hangul Syllables
                 0x1100...0x11FF,   // Hangul Jamo
                 0x3130...0x318F,   // Hangul Compatibility Jamo
                 0x4E00...0x9FFF,   // CJK Unified Ideographs
                 0x3040...0x30FF,   // Hiragana + Katakana
                 0x3400...0x4DBF,   // CJK Extension A
                 0xF900...0xFAFF:   // CJK Compatibility Ideographs
                return true
            default:
                return false
            }
        }
    }
    static func visibleText(_ source: String) -> String {
        source.replacingOccurrences(of: " ", with: "\u{00A0}")
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
