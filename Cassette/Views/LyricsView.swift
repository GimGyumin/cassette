// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI
import Translation
import SwiftSonic
import OSLog

/// How densely lyric lines pack in the viewport.
enum LyricsViewportDensity: Equatable {
    /// Phone full-player lyrics — tighter stack.
    case compact
    /// Wide / iPad lyrics panel — denser stack, more lines on screen.
    case spacious
}

struct LyricsView: View {
    @Bindable var viewModel: LyricsViewModel
    /// Apple Music–style full player uses centered lines; iOS / side panels stay leading.
    var lineAlignment: HorizontalAlignment = .leading
    var density: LyricsViewportDensity = .compact
    /// Height of player chrome drawn over the bottom of this view (scrubber / transport).
    /// Applied as scroll content margins so auto-scroll anchors above the obscured region.
    var bottomChromeInset: CGFloat = 0
    /// Reveals the full-player transport while the user taps or browses the lyrics.
    var onInteraction: (() -> Void)? = nil
    /// When chrome is hidden, the first tap only reveals it. It must not also seek
    /// to a partially obscured line under the returning transport controls.
    var consumesLineTapToRevealChrome = false
    @ObservedObject private var settings = LyricsTranslationSettings.shared
    @AppStorage("cassette.lyrics.largerText") private var largerLyricsText = "lyrics"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    @State private var translationConfiguration: TranslationSession.Configuration?
    @State private var translationStrategy: LyricsTranslationStrategy = .standard
    @State private var translationSourceLanguageCode: String?
    /// Bumped whenever the Apple session must die; in-flight work checks this before touching `session`.
    @State private var translationEpoch: Int = 0

    private var lineFrameAlignment: Alignment {
        lineAlignment == .center ? .center : .leading
    }

    private var lineTextAlignment: TextAlignment {
        lineAlignment == .center ? .center : .leading
    }

    /// Gap indicator follows the default layout (not a vocal part).
    private var gapFrameAlignment: Alignment {
        viewModel.usesSpeakerLayout ? .center : lineFrameAlignment
    }

    private func rowAlignment(at index: Int) -> (
        horizontal: HorizontalAlignment,
        text: TextAlignment,
        frame: Alignment
    ) {
        if viewModel.usesSpeakerLayout {
            let side = viewModel.speakerSide(at: index)
            return (side.horizontalAlignment, side.textAlignment, side.frameAlignment)
        }
        return (lineAlignment, lineTextAlignment, lineFrameAlignment)
    }

    private var translationsLikelyVisible: Bool {
        (viewModel.areTranslationsVisible && settings.isTranslationEnabled)
            || viewModel.selectedServerTranslationLang != nil
            || viewModel.translatedLyrics.contains { !$0.pronunciationText.isEmpty }
    }

    /// Primary lyric point size — match Apple Music's large heavy lyric type.
    private var primaryFontSize: CGFloat {
        switch density {
        case .compact: return viewModel.usesSpeakerLayout ? 36 : 34
        case .spacious: return viewModel.usesSpeakerLayout ? 40 : 38
        }
    }

    /// Fixed spacing — never derived from viewport height (that feedback loop cooked the main thread).
    private var lineStackSpacing: CGFloat {
        if viewModel.usesSpeakerLayout {
            return density == .compact ? 44 : 40
        }
        switch density {
        case .compact: return 38
        case .spacious: return translationsLikelyVisible ? 28 : 32
        }
    }

    /// Extra scroll room beyond chrome inset so the next line can sit in the clear viewport.
    private var scrollBottomPadding: CGFloat {
        density == .spacious ? 100 : 120
    }

    /// Active line sits in the upper portion of the *unobscured* viewport (chrome inset applied).
    private var currentLineScrollAnchor: UnitPoint {
        switch density {
        case .compact: return UnitPoint(x: 0.5, y: 0.22)
        case .spacious: return UnitPoint(x: 0.5, y: 0.28)
        }
    }
    
    private var sourceLanguageCode: String {
        guard case .loaded(let structured) = viewModel.state else { return "en" }
        return LyricsLanguage.resolvedSourceLanguage(from: structured.lang)
    }

    /// User's chosen translation target (not rewritten).
    private var targetLanguageCode: String {
        LyricsTranslationSettings.normalizedLanguageCode(settings.targetLanguage)
    }

    private func shouldShowTranslation(for line: TranslatedLyric) -> Bool {
        viewModel.areTranslationsVisible
            && !line.translatedText.isEmpty
            && line.translatedText != line.originalText
            && (
                viewModel.selectedServerTranslationLang != nil
                    || (
                        settings.isTranslationEnabled
                            && LyricsLanguage.shouldTranslateRow(
                                line.originalText,
                                targetCode: targetLanguageCode
                            )
                    )
            )
    }

    @ViewBuilder
    private var loadedContent: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: lineStackSpacing) {
                    Color.clear
                        .frame(width: 0, height: 0)
                        .frame(maxWidth: .infinity)
                    if viewModel.instrumentalGapAfterIndex == nil,
                       viewModel.instrumentalGapProgress != nil {
                        LyricsInstrumentalGapLeaf(viewModel: viewModel)
                            .id("instrumental-gap")
                            .frame(maxWidth: .infinity, alignment: gapFrameAlignment)
                    }

                    ForEach(
                        Array(viewModel.translatedLyrics.enumerated()),
                        id: \.offset
                    ) { index, line in
                        if viewModel.shouldHideStandaloneBacking(at: index) {
                            EmptyView()
                        } else {
                            let rowAlign = rowAlignment(at: index)
                            LyricsPlaybackLineRow(
                                viewModel: viewModel,
                                index: index,
                                line: line,
                                showTranslation: shouldShowTranslation(for: line),
                                pronunciationText: viewModel.arePronunciationsVisible ? line.pronunciationText : "",
                                prefersPronunciationAsPrimary: largerLyricsText == "pronunciation",
                                reduceMotion: reduceMotion,
                                alignment: rowAlign.horizontal,
                                textAlignment: rowAlign.text,
                                primaryFontSize: primaryFontSize,
                                usesSpeakerLayout: viewModel.usesSpeakerLayout,
                                onTap: {
                                    if consumesLineTapToRevealChrome {
                                        onInteraction?()
                                    } else {
                                        viewModel.userTapped(lineIndex: index)
                                    }
                                }
                            )
                        }

                        if viewModel.instrumentalGapAfterIndex == index,
                           viewModel.instrumentalGapProgress != nil {
                            LyricsInstrumentalGapLeaf(viewModel: viewModel)
                                .id("instrumental-gap")
                                .frame(maxWidth: .infinity, alignment: gapFrameAlignment)
                        }
                    }

                    if let songwriters = viewModel.songwritersText {
                        Text(songwriters)
                            .font(.system(size: max(14, primaryFontSize * 0.4), weight: .regular))
                            .foregroundColor(.white.opacity(0.35))
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 24)
                            .id("songwriters")
                    }

                    if viewModel.showsAutomaticallyGeneratedTranslationAttribution {
                        Label {
                            Text("Automatically generated translation")
                        } icon: {
                            Image(systemName: "sparkles")
                        }
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white.opacity(0.34))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .transition(.opacity)
                        .id("translation-attribution")
                    }
                }
                .animation(
                    reduceMotion ? nil : .easeInOut(duration: 0.38),
                    value: viewModel.areTranslationsVisible
                )
                .padding(.top, density == .spacious ? 8 : 40)
                .padding(.bottom, scrollBottomPadding)
            }
            .cassetteHideScrollEdgeEffects()
            .contentMargins(.bottom, bottomChromeInset, for: .scrollContent)
            .contentMargins(.bottom, bottomChromeInset, for: .scrollIndicators)
            .simultaneousGesture(
                DragGesture(minimumDistance: 3)
                    .onChanged { _ in
                        viewModel.userStartedScrolling()
                        onInteraction?()
                    }
                    .onEnded { _ in
                        viewModel.userStoppedScrolling()
                        onInteraction?()
                    }
            )
            .simultaneousGesture(
                TapGesture().onEnded { onInteraction?() }
            )
            .onChange(
                of: viewModel.currentLineIndex
            ) { _, newIndex in
                scrollToCurrentLine(proxy: proxy, index: newIndex)
            }
            .onChange(of: bottomChromeInset) { _, _ in
                if viewModel.instrumentalGapProgress != nil {
                    scrollToInstrumentalGap(proxy: proxy)
                } else {
                    scrollToCurrentLine(proxy: proxy, index: viewModel.currentLineIndex)
                }
            }
            .onChange(of: viewModel.instrumentalGapProgress != nil) { _, showingGap in
                if showingGap {
                    scrollToInstrumentalGap(proxy: proxy)
                }
            }
            .onChange(of: viewModel.scrollRestoreToken) { _, _ in
                if viewModel.instrumentalGapProgress != nil {
                    withAnimation(CassetteAnimation.lyricScroll) {
                        proxy.scrollTo("instrumental-gap", anchor: currentLineScrollAnchor)
                    }
                } else if let tappedIndex = viewModel.pendingSeekScrollIndex {
                    viewModel.pendingSeekScrollIndex = nil
                    withAnimation(CassetteAnimation.lyricScroll) {
                        proxy.scrollTo(tappedIndex, anchor: currentLineScrollAnchor)
                    }
                } else {
                    forceScrollToCurrentLine(proxy: proxy, index: viewModel.currentLineIndex)
                }
            }
        }
    }

    private var stateContent: some View {
        Group {
            switch viewModel.state {
            case .loading:
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .empty:
                ContentUnavailableView(
                    "No Lyrics",
                    systemImage: "music.note.list",
                    description: Text("No lyrics are available for this song.")
                )
            case .unsupported:
                ContentUnavailableView(
                    "Unsupported Server",
                    systemImage: "exclamationmark.triangle",
                    description: Text("This server doesn't support lyrics.")
                )
            case .error(let message):
                ContentUnavailableView(
                    "Unable to Load Lyrics",
                    systemImage: "wifi.exclamationmark",
                    description: Text(message)
                )
            case .loaded:
                loadedContent
            }
        }
    }

    var body: some View {
        ZStack {
            stateContent
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let message = viewModel.translationErrorMessage {
                HStack(spacing: 12) {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        Task { await viewModel.translateCurrentLyrics() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "Retry", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                }
                .padding(.horizontal, 16)
                .background(.regularMaterial)
            }
        }
        .onAppear {
            viewModel.setVisible(true)
            if settings.provider == .apple,
               viewModel.isTranslating,
               translationConfiguration == nil {
                Task { await triggerAppleTranslation() }
            }
        }
        .onDisappear {
            tearDownAppleTranslationSession()
            viewModel.setVisible(false)
        }
        .onChange(of: viewModel.isPlaying) { _, _ in
            viewModel.reconcileTracking()
        }
        .onChange(of: viewModel.followsPlayback) { _, _ in
            viewModel.reconcileTracking()
        }
        .onChange(of: scenePhase) { _, phase in
            viewModel.setScenePhase(phase)
        }
        .onChange(of: viewModel.appleTranslationRequestID) { _, _ in
            guard settings.provider == .apple else { return }
            Task { await triggerAppleTranslation() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .cassetteRoutePickerWillPresent)) { _ in
            tearDownAppleTranslationSession()
            viewModel.suspendTranslationForRoutePicker()
        }
        .onReceive(NotificationCenter.default.publisher(for: .cassetteRoutePickerDidDismiss)) { _ in
            viewModel.resumeTranslationAfterRoutePickerIfNeeded()
        }
        .translationTask(translationConfiguration) { session in
            let epoch = await MainActor.run { translationEpoch }
            let requestID = await MainActor.run { viewModel.appleTranslationRequestID }
            let requestedStrategy = await MainActor.run { translationStrategy }
            guard viewModel.beginAppleTranslationSession(requestID: requestID) else { return }

            guard settings.provider == .apple,
                  case .loaded = viewModel.state else {
                await viewModel.failAppleTranslation()
                return
            }

            let target = targetLanguageCode
            let originalTexts = viewModel.displayRows.map { row -> String in
                guard !row.isSecondaryAgent else { return "" }
                return LyricsLanguage.shouldTranslateRow(row.text, targetCode: target) ? row.text : ""
            }
            let chorusTexts = viewModel.displayRows.map { row -> String in
                guard !row.isSecondaryAgent, !row.backgroundWords.isEmpty else { return "" }
                let chorus = LyricKaraokeText.chorusText(from: row.backgroundWords)
                return LyricsLanguage.shouldTranslateRow(chorus, targetCode: target) ? chorus : ""
            }
            let batchTexts = originalTexts + chorusTexts

            let nonEmptyCount = batchTexts.reduce(0) {
                $0 + ($1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0 : 1)
            }
            guard nonEmptyCount > 0 else {
                await viewModel.failAppleTranslation(
                    message: String(localized: "No lyrics need translation.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
                )
                return
            }

            let translationService = LyricsTranslationService.shared

            do {
                let translatedTexts = try await translationService.translate(
                    lines: batchTexts,
                    using: session
                )

                try Task.checkCancellation()
                let stillCurrent = await MainActor.run {
                    translationEpoch == epoch && viewModel.appleTranslationRequestID == requestID
                }
                guard stillCurrent else {
                    return
                }

                var finalTranslatedTexts: [String] = []
                for idx in viewModel.displayRows.indices {
                    if idx < translatedTexts.count {
                        let translated = translatedTexts[idx]
                        if translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            finalTranslatedTexts.append("")
                        } else {
                            finalTranslatedTexts.append(translated)
                        }
                    } else {
                        finalTranslatedTexts.append("")
                    }
                }

                let chorusOffset = viewModel.displayRows.count
                let finalChorusTexts = viewModel.displayRows.indices.map { index in
                    let translatedIndex = chorusOffset + index
                    guard translatedTexts.indices.contains(translatedIndex) else { return "" }
                    return translatedTexts[translatedIndex]
                }

                await viewModel.applyAppleTranslation(
                    finalTranslatedTexts,
                    chorusTexts: finalChorusTexts,
                    requestID: requestID,
                    trackID: viewModel.songId
                )
            } catch is CancellationError {
                translationService.debugCancellation(trackID: viewModel.songId)
                await MainActor.run {
                    if translationEpoch == epoch && viewModel.appleTranslationRequestID == requestID {
                        viewModel.abandonAppleTranslation()
                    }
                }
            } catch {
                let stillCurrent = await MainActor.run {
                    translationEpoch == epoch && viewModel.appleTranslationRequestID == requestID
                }
                guard stillCurrent else { return }

                if requestedStrategy != .standard {
                    translationService.debugFallback(trackID: viewModel.songId)
                    await MainActor.run {
                        retryAppleTranslation(after: requestedStrategy)
                    }
                    return
                }

                Logger.lyrics.error("Apple Translation failed: \(error.localizedDescription, privacy: .public)")
                await viewModel.failAppleTranslation(message: error.localizedDescription)
            }
        }
    }

    @MainActor
    private func tearDownAppleTranslationSession() {
        translationEpoch += 1
        guard translationConfiguration != nil else { return }
        translationConfiguration = nil
    }

    private func scrollToCurrentLine(proxy: ScrollViewProxy, index: Int?) {
        guard
            viewModel.followsPlayback,
            viewModel.instrumentalGapProgress == nil,
            let index,
            viewModel.autoScrollEnabled
        else {
            return
        }
        guard !viewModel.isUserScrolling else { return }
        // Pause auto-scroll while a chorus block is active — the layout shift
        // from Dynamic Chorus Insertion must not fight the scroll animation.
        guard !viewModel.isChorusActive else { return }

        if reduceMotion {
            proxy.scrollTo(index, anchor: currentLineScrollAnchor)
        } else {
            withAnimation(CassetteAnimation.lyricScroll) {
                proxy.scrollTo(index, anchor: currentLineScrollAnchor)
            }
        }
    }

    private func forceScrollToCurrentLine(proxy: ScrollViewProxy, index: Int?) {
        guard
            viewModel.followsPlayback,
            viewModel.instrumentalGapProgress == nil,
            let index,
            viewModel.autoScrollEnabled
        else {
            return
        }

        if reduceMotion {
            proxy.scrollTo(index, anchor: currentLineScrollAnchor)
        } else {
            withAnimation(CassetteAnimation.lyricScroll) {
                proxy.scrollTo(index, anchor: currentLineScrollAnchor)
            }
        }
    }

    private func scrollToInstrumentalGap(proxy: ScrollViewProxy) {
        guard
            viewModel.followsPlayback,
            !viewModel.isUserScrolling,
            viewModel.autoScrollEnabled
        else {
            return
        }
        // Pause during chorus insertion — same reason as scrollToCurrentLine.
        guard !viewModel.isChorusActive else { return }

        if reduceMotion {
            proxy.scrollTo("instrumental-gap", anchor: currentLineScrollAnchor)
        } else {
            withAnimation(CassetteAnimation.lyricScroll) {
                proxy.scrollTo("instrumental-gap", anchor: currentLineScrollAnchor)
            }
        }
    }

    @MainActor
    private func triggerAppleTranslation() async {
        let target = targetLanguageCode
        guard case .loaded(let structured) = viewModel.state else {
            await viewModel.failAppleTranslation()
            return
        }
        let displayedLines = viewModel.displayRows.map(\.text)
        guard LyricsLanguage.needsTranslation(lines: displayedLines, targetCode: target) else {
            await viewModel.failAppleTranslation(message: String(localized: "No lyrics need translation.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
            return
        }

        let source = LyricsLanguage.resolvedSourceLanguage(from: structured.lang)
        let sourceLanguageCode = LyricsTranslationService.shared.detectedSourceLanguage(
            lines: displayedLines,
            metadataLanguageCode: source,
            targetLanguageCode: target
        )
        let sampleText = displayedLines.first {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } ?? ""
        let strategy: LyricsTranslationStrategy
        switch settings.strategyPreference {
        case .automatic:
            strategy = await LyricsTranslationService.shared.preferredStrategy(
                sourceLanguageCode: sourceLanguageCode,
                targetLanguageCode: target,
                sampleText: sampleText
            )
        case .highFidelity:
            strategy = .highFidelity
        case .lowLatency:
            strategy = .lowLatency
        case .standard:
            strategy = .standard
        }

        translationSourceLanguageCode = sourceLanguageCode
        translationStrategy = strategy
        installAppleTranslationConfiguration(target: target, strategy: strategy)
        LyricsTranslationService.shared.debugStart(
            trackID: viewModel.songId,
            sourceLanguage: source,
            targetLanguage: target,
            strategy: strategy,
            lineCount: viewModel.displayRows.count,
            cacheHit: false
        )
    }

    @MainActor
    private func retryAppleTranslation(after failedStrategy: LyricsTranslationStrategy) {
        guard case .loaded = viewModel.state else { return }
        let fallback: LyricsTranslationStrategy = failedStrategy == .highFidelity
            ? .lowLatency
            : .standard
        translationStrategy = fallback
        installAppleTranslationConfiguration(
            target: targetLanguageCode,
            strategy: fallback
        )
    }

    @MainActor
    private func installAppleTranslationConfiguration(
        target: String,
        strategy: LyricsTranslationStrategy
    ) {
        translationEpoch += 1
        var configuration = LyricsTranslationService.shared.configuration(
            sourceLanguageCode: translationSourceLanguageCode,
            targetLanguageCode: target,
            strategy: strategy
        )
        if translationConfiguration == configuration {
            configuration.invalidate()
        }
        translationConfiguration = configuration
    }

}
