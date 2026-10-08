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
        if let progress = viewModel.instrumentalGapProgress {
            LyricInstrumentalDotsView(progress: progress)
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
    var primaryFontSize: CGFloat = 34
    var usesSpeakerLayout: Bool = false
    let onTap: () -> Void

    private var followsPlayback: Bool { viewModel.followsPlayback }
    private var isSecondary: Bool { viewModel.isSecondaryAgent(at: index) }
    private var isCurrent: Bool { followsPlayback && viewModel.activeLineIndices.contains(index) }
    private var currentLineIndex: Int? { viewModel.currentLineIndex }
    private var karaokeByteEnd: Int? { isCurrent ? viewModel.karaokeByteEnds[index] : nil }
    private var cueLine: CueLine? { viewModel.cueLine(at: index) }
    private var karaokeMs: Int { viewModel.karaokePlaybackMs }
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
        if isSecondary { return isCurrent ? 0.62 : 0.28 }
        if isCurrent { return 1 }
        guard let currentLineIndex else { return 0.30 }
        switch abs(index - currentLineIndex) {
        case 1: return 0.55; case 2: return 0.40; case 3: return 0.28; default: return 0.22
        }
    }
    private var emphasisScale: CGFloat { guard followsPlayback else { return 1 }; return isCurrent ? 1.0 : 0.985 }
    /// Keep word-timed TTML text out of a blur render pass. Its per-word masks update every
    /// playback tick, and animating a blurred row while scrolling can leave stale glyph textures.
    private var emphasisBlur: CGFloat {
        guard !isTTMLWordTiming, followsPlayback, !isCurrent, let currentLineIndex else { return 0 }
        if isSecondary { return 1.4 }
        switch abs(index - currentLineIndex) {
        case 1: return 0.8
        case 2: return 1.8
        default: return 2.8
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
    private var chorusTranslationTransition: AnyTransition {
        reduceMotion ? .opacity : .offset(y: 16).combined(with: .opacity)
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
                            LyricWordKaraokeLine(
                                words: pronunciationWords,
                                adjustedMs: isCurrent ? karaokeMs : (pronunciationWords.first?.startMs ?? 0) - 1,
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
                        LyricWordKaraokeLine(
                            words: viewModel.displayWords(at: index), cueLine: cueLine,
                            adjustedMs: isCurrent ? karaokeMs : (viewModel.displayWords(at: index).first?.startMs ?? cueLine?.cue.first?.start ?? 0) - 1,
                            nextLineStartMs: nextLyricStartMs, fontSize: resolvedFontSize,
                            isSecondary: isSecondary, textAlignment: textAlignment, reduceMotion: reduceMotion
                        )
                    } else {
                        Text(LyricKaraokeText.attributed(line.originalText, activeThroughByteEnd: karaokeByteEnd,
                            isCurrent: isCurrent && !isSecondary, followsPlayback: followsPlayback, fontSize: resolvedFontSize))
                    }
                }
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
                        LyricWordKaraokeLine(words: pronunciationWords,
                            adjustedMs: isCurrent ? karaokeMs : (pronunciationWords.first?.startMs ?? 0) - 1,
                            fontSize: max(16, primaryFontSize * 0.46), textAlignment: textAlignment, reduceMotion: reduceMotion)
                    } else {
                        Text(pronunciationText)
                        .font(.system(size: max(16, primaryFontSize * 0.46), weight: .semibold))
                        .foregroundColor(followsPlayback ? (isCurrent ? .white.opacity(0.72) : .white.opacity(0.28)) : .white.opacity(0.55))
                        .opacity(secondaryLyricOpacity).multilineTextAlignment(textAlignment).fixedSize(horizontal: false, vertical: true)
                    }
                }

                // 3. Backing overlay
                if !isSecondary, isCurrent, currentLineIndex == index {
                    ForEach(viewModel.activeBackingOverlayIndices(underLead: index), id: \.self) { bi in
                        let text = viewModel.translatedLyrics.indices.contains(bi) ? viewModel.translatedLyrics[bi].originalText : ""
                        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            if let cue = viewModel.cueLine(at: bi), !cue.cue.isEmpty {
                                LyricWordKaraokeLine(words: viewModel.displayWords(at: bi), cueLine: cue,
                                    adjustedMs: karaokeMs, fontSize: primaryFontSize * 0.62, isSecondary: true,
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
                        .multilineTextAlignment(textAlignment).fixedSize(horizontal: false, vertical: true)
                        .transition(translationTransition)
                }

                // 5. Chorus — word-by-word karaoke fill for original (same engine as lead vocal).
                //    Only when bgWords (English x-bg) exist on this lead row.
                if isCurrent, !isSecondary {
                    let bgWords = viewModel.displayBackgroundWords(at: index)
                    if !bgWords.isEmpty,
                       karaokeMs >= (bgWords.map(\.startMs).min() ?? 0),
                       karaokeMs < (bgWords.map(\.endMs).max() ?? 0) {
                        let transText = line.backgroundTranslation.trimmingCharacters(in: .whitespacesAndNewlines)
                        VStack(alignment: alignment, spacing: 3) {
                            LyricWordKaraokeLine(
                                words: bgWords,
                                cueLine: nil,
                                adjustedMs: karaokeMs,
                                nextLineStartMs: nil,
                                fontSize: translationFontSize * 0.92,
                                isSecondary: true,
                                textAlignment: textAlignment,
                                reduceMotion: reduceMotion
                            )
                            let pronunciation = viewModel.pronunciationWords(at: index, background: true)
                            if !pronunciation.isEmpty {
                                LyricWordKaraokeLine(words: pronunciation, adjustedMs: karaokeMs,
                                    fontSize: translationFontSize * 0.80, isSecondary: true,
                                    textAlignment: textAlignment, reduceMotion: reduceMotion)
                            }
                            if showTranslation, !transText.isEmpty {
                                Text(transText)
                                    .font(.system(size: translationFontSize * 0.80, weight: .regular))
                                    .foregroundColor(.white.opacity(0.55)).multilineTextAlignment(textAlignment)
                                    .fixedSize(horizontal: false, vertical: true).transition(chorusTranslationTransition)
                            }
                        }
                        .transition(chorusTranslationTransition)
                    }
                }
            }
            .opacity(emphasisOpacity)
            .blur(radius: emphasisBlur)
            .scaleEffect(emphasisScale, anchor: scaleAnchor)
            .offset(y: isCurrent ? -6 : 0)
            .animation(reduceMotion || isTTMLWordTiming ? nil : CassetteAnimation.lyricLine, value: isCurrent)
            .animation(translationAnimation, value: showTranslation)
            .padding(.horizontal, usesSpeakerLayout ? 18 : 16)
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
