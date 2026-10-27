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
    /// Short phone-landscape viewports must account for the whole translated row.
    var usesMeasuredScrollAnchor = false
    var phoneLandscape = false
    /// Height of player chrome drawn over the bottom of this view (scrubber / transport).
    /// Applied as scroll content margins so auto-scroll anchors above the obscured region.
    var bottomChromeInset: CGFloat = 0
    /// Fade only the scrolling lyrics; the shared backdrop and overlaid buttons stay clear.
    var fadesTopEdge = true
    var fadesBottomEdge = true
    /// Reveals the full-player transport while the user taps or browses the lyrics.
    var onInteraction: (() -> Void)? = nil
    /// When chrome is hidden, the first tap only reveals it. It must not also seek
    /// to a partially obscured line under the returning transport controls.
    var consumesLineTapToRevealChrome = false
    /// Compact player keeps its lazy lyric tree mounted across cover morphs. Other hosts
    /// retain the normal appearance lifecycle by leaving this nil.
    var presentationIsVisible: Bool? = nil
    @State private var visibilityOwner = UUID()
    @ObservedObject private var settings = LyricsTranslationSettings.shared
    @AppStorage("cassette.lyrics.largerText") private var largerLyricsText = "lyrics"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    @State private var translationConfiguration: TranslationSession.Configuration?
    @State private var translationStrategy: LyricsTranslationStrategy = .standard
    @State private var translationSourceLanguageCode: String?
    /// Bumped whenever the Apple session must die; in-flight work checks this before touching `session`.
    @State private var translationEpoch: Int = 0
    @State private var explicitlyScrolledSeekIndex: Int?
    @State private var lastAutoScrolledIndex: Int?
    @State private var viewportHeight: CGFloat = 0
    @State private var rowHeights: [Int: CGFloat] = [:]
    @State private var lastAMLLSeekRevision = 0

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

    private var instrumentalGapInset: CGFloat {
        phoneLandscape ? 16 : (density == .compact ? 32 : 16)
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
        if phoneLandscape { return 34 }
        switch density {
        case .compact: return 36
        case .spacious: return viewModel.usesSpeakerLayout ? 40 : 38
        }
    }

    /// Fixed spacing — never derived from viewport height (that feedback loop cooked the main thread).
    private var lineStackSpacing: CGFloat {
        if viewModel.usesSpeakerLayout {
            return density == .compact ? 44 : 40
        }
        switch density {
        case .compact: return 32
        case .spacious: return translationsLikelyVisible ? 28 : 32
        }
    }

    /// Extra scroll room beyond chrome inset so the next line can sit in the clear viewport.
    private var scrollBottomPadding: CGFloat {
        density == .spacious ? 160 : 120
    }

    /// Keep the baseline region stable when chrome expands the viewport. A fixed
    /// fractional anchor otherwise pushes the active verse down as controls hide.
    private var currentLineScrollAnchor: UnitPoint {
        scrollAnchor(for: viewModel.currentLineIndex)
    }

    private func scrollAnchor(for index: Int?) -> UnitPoint {
        guard viewportHeight > 0, density == .compact || usesMeasuredScrollAnchor else {
            return UnitPoint(x: 0.5, y: density == .compact ? 0.22 : 0.28)
        }
        let rowHeight = index.flatMap { rowHeights[$0] } ?? primaryFontSize * 2.4
        return UnitPoint(x: 0.5, y: LyricScrollGeometry.anchor(
            viewportHeight: viewportHeight, bottomInset: bottomChromeInset, rowHeight: rowHeight, preferredTop: phoneLandscape ? 40 : 64))
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
                       viewModel.hasInstrumentalGap {
                        LyricsInstrumentalGapLeaf(viewModel: viewModel)
                            .id("instrumental-gap")
                            .padding(.horizontal, instrumentalGapInset)
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
                                horizontalInset: phoneLandscape ? 0 : (density == .compact ? 32 : 16),
                                onTap: {
                                    if consumesLineTapToRevealChrome {
                                        onInteraction?()
                                    } else {
                                        viewModel.userTapped(lineIndex: index)
                                    }
                                }
                            )
                            .onGeometryChange(for: CGFloat.self) { geometry in
                                geometry.size.height.rounded(.up)
                            } action: { height in
                                guard rowHeights[index] != height else { return }
                                rowHeights[index] = height
                                if viewModel.currentLineIndex == index {
                                    scrollToCurrentLine(proxy: proxy, index: index)
                                }
                            }
                        }

                        if viewModel.instrumentalGapAfterIndex == index,
                           viewModel.hasInstrumentalGap {
                            LyricsInstrumentalGapLeaf(viewModel: viewModel)
                                .id("instrumental-gap")
                                .padding(.horizontal, instrumentalGapInset)
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
            .onGeometryChange(for: CGFloat.self) { geometry in
                geometry.size.height.rounded(.up)
            } action: { height in
                viewportHeight = height
                scrollToCurrentLine(proxy: proxy, index: viewModel.currentLineIndex)
            }
            .cassetteHideScrollEdgeEffects()
            .contentMargins(.bottom, bottomChromeInset, for: .scrollContent)
            .contentMargins(.bottom, bottomChromeInset, for: .scrollIndicators)
            .cassetteContentEdgeFade(top: fadesTopEdge ? 52 : 0, bottom: fadesBottomEdge ? (phoneLandscape ? 120 : 88) : 0)
            .onScrollPhaseChange { _, phase in
                if phase == .interacting || phase == .tracking {
                    viewModel.userStartedScrolling()
                    onInteraction?()
                } else if phase == .idle {
                    viewModel.userStoppedScrolling()
                }
            }
            .simultaneousGesture(
                TapGesture().onEnded { onInteraction?() }
            )
            .onChange(
                of: viewModel.currentLineIndex
            ) { _, newIndex in
                if let explicit = explicitlyScrolledSeekIndex {
                    if newIndex == explicit { return }
                    explicitlyScrolledSeekIndex = nil
                }
                // A tapped line has one explicit scroll token. Do not launch a second
                // competing animation from its synchronous highlight update.
                guard viewModel.pendingSeekScrollIndex == nil else { return }
                scrollToCurrentLine(proxy: proxy, index: newIndex)
            }
            .onChange(of: bottomChromeInset) { _, _ in
                guard viewModel.pendingSeekScrollIndex == nil,
                      explicitlyScrolledSeekIndex == nil || explicitlyScrolledSeekIndex != viewModel.currentLineIndex else { return }
                if viewModel.hasInstrumentalGap {
                    scrollToInstrumentalGap(proxy: proxy)
                } else {
                    scrollToCurrentLine(proxy: proxy, index: viewModel.currentLineIndex)
                }
            }
            .task(id: LyricLayoutConfiguration(translations: viewModel.areTranslationsVisible,
                pronunciations: viewModel.arePronunciationsVisible, primary: largerLyricsText)) {
                // Let the new text blocks participate in layout before anchoring.
                await Task.yield()
                guard !Task.isCancelled, !viewModel.isUserScrolling else { return }
                scrollToCurrentLine(proxy: proxy, index: viewModel.currentLineIndex)
            }
            .onChange(of: viewModel.hasInstrumentalGap) { _, showingGap in
                if showingGap {
                    scrollToInstrumentalGap(proxy: proxy)
                }
            }
            .onChange(of: viewModel.scrollRestoreToken) { _, _ in
                if viewModel.hasInstrumentalGap {
                    withAnimation(reduceMotion ? nil : CassetteAnimation.lyricScroll) {
                        proxy.scrollTo("instrumental-gap", anchor: currentLineScrollAnchor)
                    }
                } else if let tappedIndex = viewModel.pendingSeekScrollIndex {
                    explicitlyScrolledSeekIndex = tappedIndex
                    viewModel.pendingSeekScrollIndex = nil
                    scroll(to: tappedIndex, proxy: proxy, seeking: true)
                } else {
                    forceScrollToCurrentLine(proxy: proxy, index: viewModel.currentLineIndex)
                }
            }
            .onChange(of: viewModel.playerState.pendingSeekPosition) { _, target in
                if let target {
                    viewModel.synchronizeSeekClock(to: target)
                    if let index = viewModel.currentLineIndex, !viewModel.isUserScrolling {
                        scroll(to: index, proxy: proxy, seeking: true)
                    }
                } else if !viewModel.isPlaying {
                    viewModel.synchronizeSeekClock(to: viewModel.playerState.position)
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
                    if viewModel.translationErrorOffersStandard {
                        Button(String(localized: "Use Standard Translation", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)) {
                            Task { await viewModel.useStandardTranslation() }
                        }
                        .font(.caption)
                        .disabled(viewModel.isTranslating)
                    } else if viewModel.translationErrorCanRetry {
                        Button {
                            Task { await viewModel.translateCurrentLyrics() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain)
                        .disabled(viewModel.isTranslating)
                        .accessibilityLabel(String(localized: "Retry", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                    }
                    Button { viewModel.translationErrorMessage = nil } label: {
                        Image(systemName: "xmark").frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "Dismiss", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                }
                .padding(.horizontal, 16)
                .background(.regularMaterial)
            }
        }
        .onAppear {
            viewModel.setScenePhase(scenePhase)
            viewModel.setVisible(presentationIsVisible ?? true, owner: visibilityOwner)
            if settings.provider == .apple,
               AppleIntelligenceLyricsTranslator.normalizedPrompt(viewModel.effectiveAppleIntelligencePrompt).isEmpty,
               viewModel.isTranslating,
               translationConfiguration == nil {
                let requestID = viewModel.appleTranslationRequestID
                Task { await triggerAppleTranslation(requestID: requestID) }
            }
        }
        .onDisappear {
            tearDownAppleTranslationSession()
            viewModel.setVisible(false, owner: visibilityOwner)
        }
        .task(id: settings.translationIdentity) {
            await viewModel.refreshTranslationSettingsIfNeeded()
        }
        .onChange(of: settings.translationIdentity) { _, _ in
            tearDownAppleTranslationSession()
        }
        .onChange(of: presentationIsVisible) { _, visible in
            if visible == false {
                tearDownAppleTranslationSession()
            }
            viewModel.setVisible(visible ?? true, owner: visibilityOwner)
        }
        .task(id: presentationIsVisible) {
            guard presentationIsVisible == true else { return }
            viewModel.synchronizeSeekClock(to: viewModel.playerState.pendingSeekPosition ?? viewModel.playerState.position)
            guard !Task.isCancelled else { return }
            viewModel.setVisible(true, owner: visibilityOwner)
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
        .onChange(of: viewModel.appleTranslationRequestID) { _, requestID in
            guard settings.provider == .apple, viewModel.isTranslating,
                  AppleIntelligenceLyricsTranslator.normalizedPrompt(viewModel.effectiveAppleIntelligencePrompt).isEmpty else { return }
            Task { await triggerAppleTranslation(requestID: requestID) }
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
                  AppleIntelligenceLyricsTranslator.normalizedPrompt(viewModel.effectiveAppleIntelligencePrompt).isEmpty,
                  case .loaded = viewModel.state else {
                viewModel.abandonAppleTranslation()
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
                    message: String(localized: "No lyrics need translation.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), requestID: requestID
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
                await viewModel.failAppleTranslation(error: error, requestID: requestID)
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
            !viewModel.hasInstrumentalGap,
            let index,
            viewModel.autoScrollEnabled
        else {
            return
        }
        guard !viewModel.isUserScrolling else { return }
        scroll(to: index, proxy: proxy,
               seeking: viewModel.playerState.pendingSeekPosition != nil || viewModel.justSeeked)
    }

    private func forceScrollToCurrentLine(proxy: ScrollViewProxy, index: Int?) {
        guard
            viewModel.followsPlayback,
            !viewModel.hasInstrumentalGap,
            let index,
            viewModel.autoScrollEnabled
        else {
            return
        }

        scroll(to: index, proxy: proxy, seeking: true)
    }

    private func scroll(to index: Int, proxy: ScrollViewProxy, seeking: Bool) {
        let previous = lastAutoScrolledIndex
        lastAutoScrolledIndex = index
        let isSeek = seeking || lastAMLLSeekRevision != viewModel.amllSeekRevision
        lastAMLLSeekRevision = viewModel.amllSeekRevision
        let animate = LyricScrollTiming.duration(previous: previous, target: index,
            seeking: isSeek, reduceMotion: reduceMotion) != nil
        let interval: Double? = index > 0 && viewModel.displayRows.indices.contains(index)
            ? viewModel.displayRows[index].startMs.flatMap { start in
                viewModel.displayRows[index - 1].startMs.map { Double(start - $0) }
            } : nil
        let spring = AMLLSpringPolicy.position(seeking: isSeek, intervalMs: interval)
        let animation: Animation? = animate
            ? .interpolatingSpring(mass: 1, stiffness: spring.stiffness, damping: spring.damping) : nil
        // scrollTo measures the real row, including wrapped lines and translation.
        // An absent animation jumps directly; it never sweeps across a distant verse.
        var transaction = Transaction(animation: animation)
        transaction.disablesAnimations = animation == nil
        withTransaction(transaction) { proxy.scrollTo(index, anchor: scrollAnchor(for: index)) }
    }

    private func scrollToInstrumentalGap(proxy: ScrollViewProxy) {
        guard
            viewModel.followsPlayback,
            !viewModel.isUserScrolling,
            viewModel.autoScrollEnabled
        else {
            return
        }

        if reduceMotion {
            proxy.scrollTo("instrumental-gap", anchor: currentLineScrollAnchor)
        } else {
            let spring = AMLLSpringPolicy.position(seeking: false, interlude: true, intervalMs: nil)
            withAnimation(.interpolatingSpring(mass: 1, stiffness: spring.stiffness, damping: spring.damping)) {
                proxy.scrollTo("instrumental-gap", anchor: currentLineScrollAnchor)
            }
        }
    }

    @MainActor
    private func triggerAppleTranslation(requestID: Int) async {
        guard requestID == viewModel.appleTranslationRequestID,
              viewModel.isTranslating, !Task.isCancelled,
              AppleIntelligenceLyricsTranslator.normalizedPrompt(viewModel.effectiveAppleIntelligencePrompt).isEmpty else { return }
        let target = targetLanguageCode
        guard case .loaded(let structured) = viewModel.state else {
            viewModel.abandonAppleTranslation()
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

        guard requestID == viewModel.appleTranslationRequestID,
              viewModel.isTranslating, !Task.isCancelled else { return }
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

private struct LyricLayoutConfiguration: Equatable {
    let translations: Bool
    let pronunciations: Bool
    let primary: String
}

nonisolated enum LyricScrollTiming {
    static func duration(previous: Int?, target: Int, seeking: Bool, reduceMotion: Bool) -> Double? {
        guard !reduceMotion, let previous, abs(target - previous) <= 3 else { return nil }
        return seeking ? 0.22 : 0.46
    }
}

/// ScrollView aligns the same fraction of the row and the unobscured viewport.
/// Account for the measured block height, including translations and wrapping.
nonisolated enum LyricScrollGeometry {
    static func anchor(viewportHeight: CGFloat, bottomInset: CGFloat, rowHeight: CGFloat, preferredTop: CGFloat = 64) -> CGFloat {
        let available = max(0, viewportHeight - bottomInset)
        let travel = max(0, viewportHeight - rowHeight)
        guard travel > 0, rowHeight < available else { return 0 }
        // ScrollView anchors use its full viewport, including content margins.
        // Leave the reserved bottom region clear even when the row nearly fills it.
        let top = min(preferredTop, available * 0.22, available - rowHeight)
        return max(0, min(1, top / travel))
    }
}
