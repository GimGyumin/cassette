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
    private var bw: [LyricDisplayWord] { isSecondary ? [] : resolved.filter(\.isBackground) }
    private var mi: Int? { idx(in: mw) }
    private var bi: Int? {
        if let c = bClip, adjustedMs > c { return nil }
        return idx(in: bw)
    }
    private var bClip: Int? {
        let e = bw.map(\.endMs).max()
        guard let n = nextLineStartMs else { return e }
        return e.map { min($0, n) } ?? n
    }
    private var bVis: Bool {
        guard let f = bw.first, adjustedMs >= f.startMs else { return false }
        if let c = bClip, adjustedMs > c { return false }
        return true
    }
    private var horizontalAlignment: HorizontalAlignment {
        switch textAlignment {
        case .center: return .center
        case .trailing: return .trailing
        default: return .leading
        }
    }
    private var frameAlignment: Alignment {
        switch textAlignment {
        case .center: return .center
        case .trailing: return .trailing
        default: return .leading
        }
    }

    var body: some View {
        VStack(alignment: horizontalAlignment, spacing: 6) {
            if !mw.isEmpty { KaraokeRow(words: mw, activeIdx: mi, ms: adjustedMs, fs: fontSize, sec: isSecondary, align: textAlignment, rm: reduceMotion) }
            // Background (x-bg) words are rendered as a Dynamic Lyric Insertion flow
            // block below the translation line in LyricsView — never inline here.
            // This prevents the chorus text from being drawn inside the main lyric row.
        }
        .frame(maxWidth: .infinity, alignment: frameAlignment)
    }

    // helpers
    private func idx(in wds: [LyricDisplayWord]) -> Int? {
        var found: Int?
        for (i, w) in wds.enumerated() { if w.startMs <= adjustedMs { found = i } else { break } }
        return found
    }
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

// ── per-word view ──

private struct KaraokeWord: View, Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.word == rhs.word && lhs.displayText == rhs.displayText && lhs.idx == rhs.idx
            && lhs.activeIdx == rhs.activeIdx && lhs.all[safe: lhs.idx + 1]?.startMs == rhs.all[safe: rhs.idx + 1]?.startMs && lhs.fs == rhs.fs
            && lhs.sec == rhs.sec && lhs.rm == rhs.rm
            && (lhs.role != 1 || lhs.ms == rhs.ms) && lhs.role == rhs.role
    }

    let word: LyricDisplayWord
    let displayText: String
    let idx: Int
    let activeIdx: Int?
    let all: [LyricDisplayWord]
    let ms: Int
    let fs: CGFloat
    let sec: Bool
    let rm: Bool

    var body: some View {
        ZStack(alignment: .leading) {
            // dim base — always visible
            Text(verbatim: displayText)
                .font(font)
                .foregroundStyle(Color.white.opacity(dimOpacity))
            // bright fill — masked left→right
            Text(verbatim: displayText)
                .font(font)
                .foregroundStyle(Color.white.opacity(brightOpacity))
                .mask(alignment: .leading) {
                    GeometryReader { geo in
                        Rectangle()
                            .frame(width: geo.size.width * (rm ? (role > 0 ? 1 : 0) : fillPct))
                    }
                }
        }
        .scaleEffect(rm ? 1.0 : (isCurrent ? 1.06 : 1.0))
        .animation(rm ? nil : .spring(response: 0.22, dampingFraction: 0.82), value: isCurrent)
        .fixedSize()
    }

    private var font: Font { .system(size: sec ? fs * 0.92 : fs, weight: sec ? .medium : .heavy) }
    private var role: Int { // 0=upcoming, 1=current, 2=lit/sung
        if sec {
            if let a = activeIdx { return idx <= a ? (idx == a ? 1 : 2) : 0 }
            return 0
        }
        guard let a = activeIdx else { return ms < (all.first?.startMs ?? 0) ? 0 : 2 }
        if idx > a { return 0 }
        return idx == a ? 1 : 2
    }
    private var isCurrent: Bool { role == 1 }
    private var fillPct: Double {
        guard role == 1 else { return role == 2 ? 1 : 0 }
        let b = word.startMs
        let e: Int
        if word.endMs > b { e = word.endMs }
        else if let nxt = all[safe: idx + 1], nxt.startMs > b { e = nxt.startMs }
        else { e = b + 280 }
        guard e > b else { return 1 }
        return min(1, max(0, Double(ms - b) / Double(e - b)))
    }
    private var dimOpacity: Double { role == 0 ? (sec ? 0.42 : 0.45) : (sec ? 0.55 : 0.45) }
    private var brightOpacity: Double { sec ? 0.78 : 1.0 }
}

/// Text can discard trailing breakable spaces when each timed token is a separate view.
/// Wrapping is handled by WordWrapLayout, so nonbreaking glyph spaces preserve its measured
/// separators without altering source text, cue offsets, translations or sung syllables.
nonisolated enum LyricKaraokeSpacing {
    static func displayTexts(_ words: [LyricDisplayWord], secondary: Bool) -> [String] {
        // Scan the line once, instead of scanning every word again for both Text layers.
        let hasSourceBoundaries = words.contains { isCJK($0.text) || $0.text.contains(where: \.isWhitespace) }
        return words.enumerated().map { index, word in
            let raw = secondary ? word.text.replacingOccurrences(of: "(", with: "").replacingOccurrences(of: ")", with: "") : word.text
            let text = word.preservesSourceSpacing || hasSourceBoundaries || index == words.count - 1 || raw.hasSuffix(" ")
                ? raw : raw + " "
            return visibleText(text)
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

// ── word-wrapping row Layout ──

private struct KaraokeRow: View {
    let words: [LyricDisplayWord]
    let activeIdx: Int?
    let ms: Int
    let fs: CGFloat
    let sec: Bool
    let align: TextAlignment
    let rm: Bool

    var body: some View {
        let displayTexts = LyricKaraokeSpacing.displayTexts(words, secondary: sec)
        WordWrapLayout(hAlign: align == .center ? .center : align == .trailing ? .trailing : .leading) {
            ForEach(Array(words.enumerated()), id: \.0) { i, w in
                KaraokeWord(word: w, displayText: displayTexts[i], idx: i, activeIdx: activeIdx, all: words, ms: ms, fs: fs, sec: sec, rm: rm).equatable()
            }
        }
    }
}

// ── Bounded word-wrap Layout ──

private struct WordWrapLayout: Layout {
    let hAlign: HorizontalAlignment

    private static let fallbackW: CGFloat = {
        #if os(iOS)
        // Last resort when the layout gets no width proposal. Capped at the macOS value: the raw
        // screen width is the *device* width on iPad, so an unpainted lyrics pane in Split View could
        // otherwise be laid out against a 1300 pt line.
        min(UIScreen.main.bounds.width - 80, 600)
        #else
        600
        #endif
    }()

    struct Cache {
        var sizes: [CGSize]
        var width: CGFloat?
        var rows: R?
    }

    func makeCache(subviews: Subviews) -> Cache { Cache(sizes: subviews.map { $0.sizeThatFits(.unspecified) }) }
    func updateCache(_ cache: inout Cache, subviews: Subviews) { cache = makeCache(subviews: subviews) }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let mw = maxW(proposal)
        let rows = layout(mw: mw, cache: &cache)
        return CGSize(width: min(rows.nw, mw), height: rows.th)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let mw = bounds.width > 0 ? bounds.width : maxW(proposal)
        let rows = layout(mw: mw, cache: &cache)
        var y = bounds.minY
        for (ri, row) in rows.rows.enumerated() {
            let rw = rows.rw[ri]
            let x0: CGFloat = switch hAlign {
            case .center: bounds.minX + (mw - rw) / 2
            case .trailing: bounds.minX + (mw - rw)
            default: bounds.minX
            }
            var x = x0
            let h = rows.rh[ri]
            for (sv, sz) in row {
                subviews[sv].place(at: CGPoint(x: x, y: y + (h - sz.height) / 2), proposal: ProposedViewSize(sz))
                x += sz.width
            }
            y += h
        }
    }

    private func maxW(_ p: ProposedViewSize) -> CGFloat {
        if let w = p.width, w.isFinite { return w }; return Self.fallbackW
    }

    struct R { let rows: [[(Int, CGSize)]]; let rw: [CGFloat]; let rh: [CGFloat]; let nw: CGFloat; let th: CGFloat }

    private func layout(mw: CGFloat, cache: inout Cache) -> R {
        if cache.width == mw, let rows = cache.rows { return rows }
        var rows: [[(Int, CGSize)]] = [[]]
        var rw: [CGFloat] = [0]
        var rh: [CGFloat] = [0]
        for (sv, sz) in cache.sizes.enumerated() {
            let last = rows.count - 1
            if rw[last] > 0, rw[last] + sz.width > mw { rows.append([]); rw.append(0); rh.append(0) }
            rows[rows.count - 1].append((sv, sz))
            rw[rw.count - 1] += sz.width
            rh[rh.count - 1] = max(rh[rh.count - 1], sz.height)
        }
        var th: CGFloat = 0, nw: CGFloat = 0
        for (i, h) in rh.enumerated() { nw = max(nw, rw[i]); th += h }
        let result = R(rows: rows, rw: rw, rh: rh, nw: nw, th: th)
        cache.width = mw
        cache.rows = result
        return result
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
