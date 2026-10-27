// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI
import SwiftSonic

@MainActor
struct LyricsInstrumentalGapLeaf: View {
    @Bindable var viewModel: LyricsViewModel
    var body: some View {
        if viewModel.hasInstrumentalGap {
            TimelineView(.animation(minimumInterval: PerformanceGovernor.shared.budget.lyricsRenderInterval,
                paused: !viewModel.isPlaying || !viewModel.isShown || !viewModel.isActive)) { _ in
                let elapsed = viewModel.presentationTimeMs() - viewModel.instrumentalGapStartMs
                let duration = max(1, viewModel.instrumentalGapEndMs - viewModel.instrumentalGapStartMs)
                LyricInstrumentalDotsView(progress: Double(elapsed) / Double(duration),
                    elapsedMs: Double(elapsed), durationMs: Double(duration),
                    isIntro: viewModel.instrumentalGapAfterIndex == nil,
                    allowsMotion: PerformanceGovernor.shared.budget.allowsDecorativeMotion)
            }
        }
    }
}

@MainActor
struct LyricsPlaybackLineRow: View {
    @Bindable var viewModel: LyricsViewModel
    let index: Int
    let line: TranslatedLyric
    let showTranslation: Bool
    var pronunciationText: String = ""
    var prefersPronunciationAsPrimary: Bool = false
    let reduceMotion: Bool
    var alignment: HorizontalAlignment = .leading
    var textAlignment: TextAlignment = .leading
    var primaryFontSize: CGFloat = 36
    var usesSpeakerLayout: Bool = false
    var horizontalInset: CGFloat = 32
    let onTap: () -> Void

    private var followsPlayback: Bool { viewModel.followsPlayback }
    private var isSecondary: Bool { viewModel.isSecondaryAgent(at: index) }
    private var isCurrent: Bool { followsPlayback && viewModel.emphasizedLineIndices.contains(index) }
    private var currentLineIndex: Int? { viewModel.currentLineIndex }
    private var karaokeByteEnd: Int? { isCurrent ? viewModel.karaokeByteEnds[index] : nil }
    private var cueLine: CueLine? { viewModel.cueLine(at: index) }
    private var nextLyricStartMs: Int? { viewModel.nextLyricStartMs(after: index) }
    private var isTTMLWordTiming: Bool { viewModel.lyricDocument?.timing == .word }

    private var frameAlignment: Alignment {
        switch alignment { case .center: return .center; case .trailing: return .trailing; default: return .leading }
    }
    private var scaleAnchor: UnitPoint {
        switch alignment { case .center: return .center; case .trailing: return .trailing; default: return .leading }
    }
    private var resolvedFontSize: CGFloat { isSecondary ? primaryFontSize * 0.82 : primaryFontSize }
    private var secondaryLyricOpacity: Double { isCurrent ? 1 : 0.45 }
    private var speakerSideInset: CGFloat { usesSpeakerLayout ? 64 : 0 }
    private var translationFontSize: CGFloat { max(18, resolvedFontSize * 0.52) }
    private var pronunciationIsPrimary: Bool {
        prefersPronunciationAsPrimary
            && !pronunciationText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && pronunciationText != line.originalText
            && !isSecondary
    }
    private var emphasisOpacity: Double {
        guard followsPlayback else { return 1 }
        if isSecondary { return isCurrent ? 0.82 : 0.38 }
        if isCurrent { return 1 }
        guard let currentLineIndex else { return 0.30 }
        switch abs(index - currentLineIndex) {
        case 1: return index > currentLineIndex ? 0.38 : 0.30
        case 2: return 0.28
        default: return 0.24
        }
    }
    private var emphasisScale: CGFloat { guard followsPlayback else { return 1 }; return isCurrent ? 1.0 : 0.985 }
    /// Only dormant, static text is blurred. The frame-driven active glyphs stay sharp.
    private var emphasisBlur: CGFloat {
        guard followsPlayback, !isCurrent, let currentLineIndex else { return 0 }
        if isSecondary { return 1.4 }
        switch abs(index - currentLineIndex) {
        case 1: return 2.4
        case 2: return 3.2
        default: return 4.0
        }
    }
    private var translationAnimation: Animation? { reduceMotion ? nil : .easeInOut(duration: 0.38) }
    private var translationTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(y: -6)).combined(with: .scale(scale: 0.98, anchor: scaleAnchor)),
            removal: .opacity.combined(with: .offset(y: -4))
        )
    }
    private var backingOverlayTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(y: -4)).combined(with: .scale(scale: 0.985, anchor: .topLeading)),
            removal: .opacity
        )
    }
    private func settledTime(_ words: [LyricDisplayWord]) -> Int {
        let start = words.map(\.startMs).min() ?? 0
        let end = words.map { max($0.endMs, $0.startMs + 280) }.max() ?? cueLine?.end ?? start
        return Int(AMLLGlyphStyle.settledTime(startMs: Double(start), endMs: Double(end)))
    }

    private var lineAnimation: Animation? {
        guard !reduceMotion, !viewModel.justSeeked, !viewModel.amllTransitionIsSeek,
              viewModel.playerState.pendingSeekPosition == nil else { return nil }
        // Dimming follows the vocal boundary immediately; stagger only incoming rows.
        if !isCurrent { return .easeOut(duration: 0.10) }
        let current = currentLineIndex ?? index
        let firstVisible = max(0, current - 2)
        let delay = AMLLSpringPolicy.stagger(visibleOrdinal: max(0, index - firstVisible),
            focalOrdinal: current - firstVisible, seeking: viewModel.isUserScrolling)
        return .easeOut(duration: 0.45).delay(delay)
    }

    // MARK: - Body

    var body: some View {
        if line.isBlank {
            Spacer().frame(height: max(28, primaryFontSize * 0.85)).id(index)
        } else {
            VStack(alignment: alignment, spacing: isSecondary ? 6 : 8) {
                // 1. Lead lyric
                Group {
                    if pronunciationIsPrimary {
                        let pronunciationWords = viewModel.pronunciationWords(at: index)
                        if followsPlayback, !pronunciationWords.isEmpty {
                            LyricsWordClockLine(
                                words: pronunciationWords,
                                viewModel: viewModel, followsClock: isCurrent, idleMs: settledTime(pronunciationWords),
                                fontSize: resolvedFontSize,
                                textAlignment: textAlignment,
                                reduceMotion: reduceMotion
                            )
                        } else {
                            Text(pronunciationText)
                                .font(.system(size: resolvedFontSize, weight: .bold))
                                .foregroundColor(.white)
                        }
                    } else if followsPlayback, isTTMLWordTiming {
                        LyricsWordClockLine(
                            words: viewModel.displayWords(at: index), cueLine: cueLine,
                            viewModel: viewModel, followsClock: isCurrent, idleMs: settledTime(viewModel.displayWords(at: index)),
                            nextLineStartMs: nextLyricStartMs, fontSize: resolvedFontSize,
                            isSecondary: isSecondary, textAlignment: textAlignment, reduceMotion: reduceMotion
                        )
                    } else {
                        Text(LyricKaraokeText.attributed(line.originalText, activeThroughByteEnd: karaokeByteEnd,
                            isCurrent: isCurrent, followsPlayback: followsPlayback, fontSize: resolvedFontSize, dimsInactive: false))
                    }
                }
                .lineSpacing(2)
                .multilineTextAlignment(textAlignment).fixedSize(horizontal: false, vertical: true)

                // 2. Pronunciation
                if pronunciationIsPrimary {
                    Text(line.originalText)
                        .font(.system(size: max(16, primaryFontSize * 0.46), weight: .semibold))
                        .foregroundColor(followsPlayback ? (isCurrent ? .white.opacity(0.72) : .white.opacity(0.28)) : .white.opacity(0.55))
                        .opacity(secondaryLyricOpacity)
                        .multilineTextAlignment(textAlignment)
                        .fixedSize(horizontal: false, vertical: true)
                } else if !pronunciationText.isEmpty, pronunciationText != line.originalText, !isSecondary {
                    let pronunciationWords = viewModel.pronunciationWords(at: index)
                    if followsPlayback, !pronunciationWords.isEmpty {
                        LyricsWordClockLine(words: pronunciationWords,
                            viewModel: viewModel, followsClock: isCurrent, idleMs: settledTime(pronunciationWords),
                            fontSize: max(16, primaryFontSize * 0.46), textAlignment: textAlignment, reduceMotion: reduceMotion)
                    } else {
                        Text(pronunciationText)
                        .font(.system(size: max(16, primaryFontSize * 0.46), weight: .semibold))
                        .foregroundColor(followsPlayback ? (isCurrent ? .white.opacity(0.72) : .white.opacity(0.28)) : .white.opacity(0.55))
                        .opacity(secondaryLyricOpacity).multilineTextAlignment(textAlignment).fixedSize(horizontal: false, vertical: true)
                    }
                }

                // 3. Backing overlay
                if !isSecondary, currentLineIndex == index {
                    ForEach(viewModel.activeBackingOverlayIndices(underLead: index), id: \.self) { bi in
                        let text = viewModel.translatedLyrics.indices.contains(bi) ? viewModel.translatedLyrics[bi].originalText : ""
                        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            if let cue = viewModel.cueLine(at: bi), !cue.cue.isEmpty {
                                LyricsWordClockLine(words: viewModel.displayWords(at: bi), cueLine: cue,
                                    viewModel: viewModel, followsClock: true, idleMs: 0, fontSize: primaryFontSize * 0.62, isSecondary: true,
                                    textAlignment: textAlignment, reduceMotion: reduceMotion)
                                .opacity(0.72).padding(.top, 2).transition(backingOverlayTransition)
                            } else {
                                Text(text).font(.system(size: primaryFontSize * 0.62, weight: .bold))
                                    .foregroundStyle(Color.white.opacity(0.55)).multilineTextAlignment(textAlignment)
                                    .fixedSize(horizontal: false, vertical: true).opacity(0.9).padding(.top, 2).transition(backingOverlayTransition)
                            }
                        }
                    }
                }

                // 4. Main translation
                if showTranslation, !isSecondary {
                    Text(line.translatedText)
                        .font(.system(size: translationFontSize, weight: .semibold))
                        .foregroundColor(.white.opacity(0.78)).opacity(isCurrent ? 1.0 : 0.48)
                        .lineSpacing(2)
                .multilineTextAlignment(textAlignment).fixedSize(horizontal: false, vertical: true)
                        .transition(translationTransition)
                }

                // Reserve backing layout without showing future chorus text. Its clock
                // follows x-bg timestamps, including overlap beyond the lead's end.
                if !isSecondary, !viewModel.displayBackgroundWords(at: index).isEmpty {
                    LyricsBackgroundClockBlock(viewModel: viewModel, index: index,
                        translation: showTranslation ? line.backgroundTranslation : "",
                        alignment: alignment, textAlignment: textAlignment,
                        fontSize: translationFontSize * 0.92, reduceMotion: reduceMotion)
                }
            }
            .opacity(emphasisOpacity)
            .blur(radius: emphasisBlur)
            .scaleEffect(emphasisScale, anchor: scaleAnchor)
            .offset(y: isCurrent ? -2 : 0)
            .animation(lineAnimation, value: currentLineIndex)
            .animation(lineAnimation, value: isCurrent)
            .animation(translationAnimation, value: showTranslation)
            .padding(.horizontal, usesSpeakerLayout ? 18 : horizontalInset)
            .padding(.leading, { if alignment == .trailing { return speakerSideInset }; if isSecondary { return usesSpeakerLayout ? 12 : 20 }; return 0 }())
            .padding(.trailing, alignment == .leading && usesSpeakerLayout && !isSecondary ? speakerSideInset : 0)
            .padding(.top, isSecondary ? 2 : 0)
            .frame(maxWidth: .infinity, alignment: frameAlignment).contentShape(Rectangle())
            .id(index).onTapGesture(perform: onTap)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(followsPlayback ? .isButton : [])
            .accessibilityValue(isCurrent && followsPlayback ? Text("Now Playing") : Text(""))
            .accessibilityHint(followsPlayback ? String(localized: "Seek to this line", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale) : "")
        }
    }
}

/// Only timed glyphs observe the high-frequency clock. The lyric row's translations,
/// accessibility, layout and emphasis do not need rebuilding for every word-fill sample.
private struct LyricsWordClockLine: View {
    var words: [LyricDisplayWord] = []
    var cueLine: CueLine? = nil
    let viewModel: LyricsViewModel
    let followsClock: Bool
    let idleMs: Int
    var nextLineStartMs: Int? = nil
    let fontSize: CGFloat
    var isSecondary = false
    var textAlignment: TextAlignment = .leading
    var reduceMotion = false
    @State private var governor = PerformanceGovernor.shared
    var body: some View {
        let running = followsClock && viewModel.isShown && viewModel.isActive && viewModel.isPlaying
        TimelineView(.animation(minimumInterval: governor.budget.lyricsRenderInterval, paused: !running)) { _ in
            LyricWordKaraokeLine(words: words, cueLine: cueLine,
                adjustedMs: followsClock ? viewModel.presentationTimeMs() : idleMs,
                nextLineStartMs: nextLineStartMs, fontSize: fontSize,
                isSecondary: isSecondary, textAlignment: textAlignment,
                reduceMotion: reduceMotion || !governor.budget.allowsDecorativeMotion)
                .transaction { $0.animation = nil }
        }
    }
}

/// A backing vocal can keep singing after the lead. Only this leaf reads its clock,
/// so the measured row and translation layout stay unchanged between frame samples.
struct LyricsBackgroundClockBlock: View {
    let viewModel: LyricsViewModel
    let index: Int
    let translation: String
    let alignment: HorizontalAlignment
    let textAlignment: TextAlignment
    let fontSize: CGFloat
    let reduceMotion: Bool

    var body: some View {
        let words = viewModel.displayBackgroundWords(at: index)
        let start = words.map(\.startMs).min() ?? 0
        let end = words.map(\.endMs).max() ?? start
        let time = viewModel.karaokePlaybackMs
        let active = time >= start && time < end
        let settled = Int(AMLLGlyphStyle.settledTime(startMs: Double(start), endMs: Double(end)))
        VStack(alignment: alignment, spacing: 3) {
            LyricsWordClockLine(words: words, viewModel: viewModel,
                followsClock: active, idleMs: settled, fontSize: fontSize,
                isSecondary: true, textAlignment: textAlignment, reduceMotion: reduceMotion)
            let pronunciation = viewModel.arePronunciationsVisible
                ? viewModel.pronunciationWords(at: index, background: true) : []
            if !pronunciation.isEmpty {
                LyricsWordClockLine(words: pronunciation, viewModel: viewModel,
                    followsClock: active, idleMs: settled, fontSize: fontSize * 0.87,
                    isSecondary: true, textAlignment: textAlignment, reduceMotion: reduceMotion)
            }
            if !translation.isEmpty {
                Text(translation).font(.system(size: fontSize * 0.87))
                    .foregroundStyle(.white.opacity(0.65))
                    .lineSpacing(2)
                .multilineTextAlignment(textAlignment).fixedSize(horizontal: false, vertical: true)
            }
        }
        .opacity(active || !viewModel.followsPlayback ? 1 : 0)
        .accessibilityHidden(viewModel.followsPlayback && !active)
        .allowsHitTesting(active || !viewModel.followsPlayback)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: active)
    }
}
