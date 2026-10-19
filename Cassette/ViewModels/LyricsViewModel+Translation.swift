// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI
import SwiftSonic
import Combine
import OSLog
import QuartzCore

extension LyricsViewModel {
    // MARK: Translation Core

    /// True when at least one lyric line still needs translation into the user’s target language.
    var needsTranslation: Bool {
        guard case .loaded(let structured) = state else { return false }
        // Show button if translations already exist (TTML / server / cached) — for toggle.
        if selectedServerTranslationLang != nil { return true }
        if translatedLyrics.contains(where: { !$0.translatedText.isEmpty && $0.translatedText != $0.originalText }) { return true }
        let target = LyricsTranslationSettings.normalizedLanguageCode(
            LyricsTranslationSettings.shared.targetLanguage
        )
        let source = LyricsLanguage.resolvedSourceLanguage(from: structured.lang)
        let lines = displayRows.map(\.text)
        let anyForeign = LyricsLanguage.needsTranslation(lines: lines, targetCode: target)
        // Trust the actual displayed text over server metadata. Some TTML providers label
        // mixed-language or English lyrics with the user's locale.
        if source == target && !anyForeign { return false }
        return anyForeign
    }

    func translateCurrentLyrics() async {
        await refreshTranslationSettingsIfNeeded()
        guard case .loaded(let structured) = state else { return }
        // Already have translations (TTML / server / cached API) — just toggle visibility.
        if selectedServerTranslationLang != nil || translatedLyrics.contains(where: { !$0.translatedText.isEmpty && $0.translatedText != $0.originalText }) {
            if areTranslationsVisible {
                clearTranslation()
            } else {
                revealTranslation()
            }
            return
        }
        guard needsTranslation else {
            clearTranslation()
            return
        }

        let language = languageGeneration
        // Always keep original lines on screen while a request is in flight.
        await seedOriginalLyrics(from: structured, hideTranslations: false)
        guard language == languageGeneration, !Task.isCancelled else { return }

        translationTask?.cancel()

        let settings = LyricsTranslationSettings.shared
        let provider = settings.provider
        let resolvedSource = LyricsLanguage.resolvedSourceLanguage(from: structured.lang)
        let preferredTarget = LyricsTranslationSettings.normalizedLanguageCode(settings.targetLanguage)
        // Prefer the user’s target; only rewrite when Apple would hang on identical codes.
        let finalTarget: String = {
            if preferredTarget == resolvedSource,
               LyricsLanguage.needsTranslation(lines: displayRows.map(\.text), targetCode: preferredTarget) {
                // Mixed-script lyrics with a matching metadata lang — keep user target.
                return preferredTarget
            }
            return LyricsTranslationSettings.resolvedTargetLanguage(
                preferred: preferredTarget,
                source: resolvedSource
            )
        }()

        let originalLines = displayRows.map(\.text)

        // 1. Device cache — never re-call the provider when we already have a match.
        let cachedTranslation: [TranslatedLyric]? = if provider == .apple {
            LyricsTranslationService.shared.cachedTranslation(
                songID: songId,
                sourceLanguage: resolvedSource,
                targetLanguage: finalTarget,
                originalLines: originalLines,
                strategyPreference: settings.strategyPreference,
                customPrompt: effectiveAppleIntelligencePrompt
            )
        } else {
            TranslationCache.shared.get(
                songID: songId,
                sourceLang: resolvedSource,
                targetLang: finalTarget,
                provider: provider,
                originalLines: originalLines
            )
        }
        if let cached = cachedTranslation {
            if provider == .apple {
                LyricsTranslationService.shared.debugStart(
                    trackID: songId,
                    sourceLanguage: resolvedSource,
                    targetLanguage: finalTarget,
                    strategy: .standard,
                    lineCount: originalLines.count,
                    cacheHit: true
                )
            }
            replaceTranslatedLyrics(cached, reveal: true)
            translationErrorMessage = nil
            isTranslating = false
            return
        }

        // Already holding a valid in-memory translation for this target — just reveal.
        if hasStoredTranslationMatching(originalLines: originalLines, targetCode: finalTarget) {
            revealTranslation()
            translationErrorMessage = nil
            isTranslating = false
            return
        }

        translationTask = Task { @MainActor in
            self.isTranslating = true
            self.translationErrorMessage = nil

            if provider == .openAI {
                let translator = OpenAITranslator()
                // Only send lines that are not already in the target language.
                let linesToTranslate = structured.line.map { line in
                    LyricsLanguage.shouldTranslateRow(line.value, targetCode: finalTarget) ? line.value : ""
                }

                do {
                    let translatedTexts = try await translator.translate(
                        lyrics: linesToTranslate,
                        sourceLanguage: resolvedSource,
                        targetLanguage: finalTarget
                    )

                    guard language == self.languageGeneration, !Task.isCancelled else { return }

                    let sourceTranslations: [String] = (0..<structured.line.count).map { index in
                        let line = structured.line[index]
                        let needs = LyricsLanguage.shouldTranslateRow(line.value, targetCode: finalTarget)
                        guard needs else { return "" }
                        return index < translatedTexts.count ? translatedTexts[index] : ""
                    }

                    let results = self.displayRows.enumerated().map { displayIndex, row in
                        let translated = row.isSecondaryAgent
                            ? ""
                            : (row.sourceLineIndex < sourceTranslations.count
                                ? sourceTranslations[row.sourceLineIndex]
                                : "")
                        return self.makeTranslatedLyric(
                            at: displayIndex,
                            text: row.text,
                            startMs: row.startMs,
                            translatedText: translated,
                            translationSource: .openAI
                        )
                    }

                    TranslationCache.shared.set(
                        results,
                        songID: self.songId,
                        sourceLang: resolvedSource,
                        targetLang: finalTarget,
                        provider: provider
                    )

                    self.replaceTranslatedLyrics(results, reveal: true)
                    self.isTranslating = false
                } catch {
                    guard language == self.languageGeneration, !Task.isCancelled else { return }
                    self.presentTranslationFailure(error)
                    // Keep originals visible; only clear translated rows.
                    await self.seedOriginalLyrics(from: structured, hideTranslations: true)
                    self.isTranslating = false
                }
            } else if !AppleIntelligenceLyricsTranslator.normalizedPrompt(effectiveAppleIntelligencePrompt).isEmpty {
                self.appleTranslationRequestID &+= 1
                let requestID = self.appleTranslationRequestID
                let identity = settings.translationIdentity
                let originals = self.displayRows.map { row in
                    !row.isSecondaryAgent && LyricsLanguage.shouldTranslateRow(row.text, targetCode: finalTarget)
                        ? row.text : ""
                }
                let chorus = self.displayRows.map { row in
                    let text = LyricKaraokeText.chorusText(from: row.backgroundWords)
                    return !row.isSecondaryAgent && LyricsLanguage.shouldTranslateRow(text, targetCode: finalTarget)
                        ? text : ""
                }
                do {
                    let result = try await AppleIntelligenceLyricsTranslator.shared.translate(
                        lines: originals + chorus, targetLanguage: finalTarget,
                        prompt: effectiveAppleIntelligencePrompt
                    )
                    guard language == self.languageGeneration, identity == settings.translationIdentity,
                          requestID == self.appleTranslationRequestID, !Task.isCancelled else { return }
                    await self.applyAppleTranslation(
                        Array(result.prefix(originals.count)), chorusTexts: Array(result.dropFirst(originals.count)),
                        requestID: requestID, trackID: self.songId
                    )
                } catch {
                    guard language == self.languageGeneration, identity == settings.translationIdentity,
                          requestID == self.appleTranslationRequestID, !Task.isCancelled else { return }
                    await self.failAppleTranslation(error: error, requestID: requestID)
                }
            } else {
                // Apple Translation is completed by LyricsView.translationTask → apply/fail.
                // Do not wipe originals — seed keeps them while the session runs.
                await self.seedOriginalLyrics(from: structured, hideTranslations: false)
                guard language == self.languageGeneration, !Task.isCancelled else { return }
                self.appleTranslationRequestID += 1

                // Safety: if the view never completes the session, clear the spinner.
                let requestID = self.appleTranslationRequestID
                self.appleTranslationTimeoutTask?.cancel()
                self.appleTranslationTimeoutTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 20_000_000_000)
                    guard !Task.isCancelled else { return }
                    if self.isTranslating, self.appleTranslationRequestID == requestID {
                        await self.failAppleTranslation(message: String(localized: "Translation timed out and was cancelled.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                    }
                }
            }
        }

        do {
            _ = try await translationTask?.value
        } catch {
            isTranslating = false
        }
    }

    func refreshTranslationSettingsIfNeeded() async {
        let identity = LyricsTranslationSettings.shared.translationIdentity
        guard identity != translationSettingsIdentity else { return }
        usesStandardTranslationForCurrentTrack = false
        translationSettingsIdentity = identity
        invalidateTranslationWork()
        guard selectedServerTranslationLang == nil, case .loaded(let structured) = state else { return }
        replaceTranslatedLyrics([], reveal: false)
        await seedOriginalLyrics(from: structured, hideTranslations: true)
    }



    /// The startup watchdog must not time out Apple's model-download/consent UI.
    func beginAppleTranslationSession(requestID: Int) -> Bool {
        guard requestID == appleTranslationRequestID, isTranslating else { return false }
        appleTranslationTimeoutTask?.cancel()
        appleTranslationTimeoutTask = nil
        return true
    }

    func applyAppleTranslation(
        _ translatedTexts: [String],
        chorusTexts: [String],
        requestID: Int,
        trackID: String
    ) async {
        guard requestID == appleTranslationRequestID,
              trackID == songId,
              !Task.isCancelled else { return }
        appleTranslationTimeoutTask?.cancel()
        appleTranslationTimeoutTask = nil
        guard case .loaded(let structured) = state else {
            isTranslating = false
            return
        }

        let settings = LyricsTranslationSettings.shared
        let sourceLang = LyricsLanguage.resolvedSourceLanguage(from: structured.lang)
        let preferredTarget = LyricsTranslationSettings.normalizedLanguageCode(settings.targetLanguage)
        let finalTarget = preferredTarget == sourceLang && LyricsLanguage.needsTranslation(lines: structured.line.map(\.value), targetCode: preferredTarget)
            ? preferredTarget
            : LyricsTranslationSettings.resolvedTargetLanguage(preferred: preferredTarget, source: sourceLang)

        let results = displayRows.enumerated().map { displayIndex, row in
            let translated = row.isSecondaryAgent
                ? ""
                : (displayIndex < translatedTexts.count
                    ? translatedTexts[displayIndex]
                    : "")
            let chorusTranslation = row.isSecondaryAgent
                ? ""
                : (displayIndex < chorusTexts.count
                    ? Self.normalizedChorusTranslation(chorusTexts[displayIndex])
                    : "")
            return makeTranslatedLyric(
                at: displayIndex,
                text: row.text,
                startMs: row.startMs,
                translatedText: translated,
                backgroundTranslation: chorusTranslation,
                translationSource: .appleAPI
            )
        }

        let hasMeaningfulTranslation = results.contains {
            (!$0.translatedText.isEmpty && $0.translatedText != $0.originalText)
                || !$0.backgroundTranslation.isEmpty
        }

        if hasMeaningfulTranslation {
            LyricsTranslationService.shared.storeTranslation(
                results,
                songID: songId,
                sourceLanguage: sourceLang,
                targetLanguage: finalTarget,
                strategyPreference: settings.strategyPreference,
                customPrompt: effectiveAppleIntelligencePrompt
            )
            replaceTranslatedLyrics(results, reveal: true)
            translationErrorMessage = nil
        } else {
            await seedOriginalLyrics(from: structured, hideTranslations: true)
            translationErrorMessage = String(localized: "Translation result was empty. Check the translation language in Settings.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        }

        isTranslating = false
    }

    func failAppleTranslation(message: String? = nil, requestID: Int? = nil) async {
        if let requestID, requestID != appleTranslationRequestID { return }
        guard !Task.isCancelled else { return }
        appleTranslationTimeoutTask?.cancel()
        appleTranslationTimeoutTask = nil
        isTranslating = false
        // Losing the view/document is cancellation, not a provider failure. Keep the
        // existing original rows; rebuilding them here can race a language selection.
        guard case .loaded = state else { return }
        translationErrorMessage = message ?? String(localized: "Couldn't load translation.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        translationErrorCanRetry = true
        translationErrorOffersStandard = false
    }

    func failAppleTranslation(error: Error, requestID: Int) async {
        guard requestID == appleTranslationRequestID, !Task.isCancelled else { return }
        await failAppleTranslation(requestID: requestID)
        presentTranslationFailure(error)
    }

    func presentTranslationFailure(_ error: Error) {
        let failure = LyricTranslationFailure.from(error, customPrompt: !effectiveAppleIntelligencePrompt.isEmpty)
        translationErrorMessage = failure.message
        translationErrorCanRetry = failure.canRetry
        translationErrorOffersStandard = failure.offersStandardTranslation
        Logger.lyrics.error("Translation failed: \(error, privacy: .private)")
    }

    func useStandardTranslation() async {
        await refreshTranslationSettingsIfNeeded()
        usesStandardTranslationForCurrentTrack = true
        translationErrorMessage = nil
        await translateCurrentLyrics()
    }

    /// Clears the translating spinner without showing an error (view dismissed / task cancelled).
    func abandonAppleTranslation() {
        // Route-picker suspend sets this — keep the spinner until we resume after dismiss.
        if resumeTranslationAfterRoutePicker { return }
        appleTranslationTimeoutTask?.cancel()
        appleTranslationTimeoutTask = nil
        isTranslating = false
    }

    /// Pause in-flight translation while the system route picker is on screen.
    /// Apple Translation + AVRoutePickerView presentation starves the audio thread (underruns).
    func suspendTranslationForRoutePicker() {
        let wasBusy = isTranslating || translationTask != nil
        if wasBusy {
            resumeTranslationAfterRoutePicker = true
        }
        translationTask?.cancel()
        translationTask = nil
        appleTranslationTimeoutTask?.cancel()
        appleTranslationTimeoutTask = nil
        // Keep isTranslating true when we'll resume, so the button still shows progress.
        if !resumeTranslationAfterRoutePicker {
            isTranslating = false
        }
    }

    func resumeTranslationAfterRoutePickerIfNeeded() {
        guard resumeTranslationAfterRoutePicker else { return }
        resumeTranslationAfterRoutePicker = false
        resumeTranslationTask?.cancel()
        resumeTranslationTask = Task { await translateCurrentLyrics() }
    }

    /// A language/visibility change supersedes both client providers and their watchdog.
    func invalidateTranslationWork() {
        languageGeneration &+= 1
        translationErrorMessage = nil
        translationTask?.cancel()
        translationTask = nil
        appleTranslationTimeoutTask?.cancel()
        appleTranslationTimeoutTask = nil
        isTranslating = false
        appleTranslationRequestID &+= 1
    }

    func selectServerTranslation(lang: String?) async {
        invalidateTranslationWork()
        let generation = languageGeneration
        selectedServerTranslationLang = lang
        guard case .loaded(let structured) = state else { return }
        await seedOriginalLyrics(from: structured, hideTranslations: lang == nil)
        guard generation == languageGeneration, !Task.isCancelled else { return }
        if lang != nil {
            areTranslationsVisible = true
        }
    }

    private func hasStoredTranslationMatching(
        originalLines: [String],
        targetCode: String
    ) -> Bool {
        guard translatedLyrics.count == originalLines.count else { return false }
        for (lyric, original) in zip(translatedLyrics, originalLines) {
            guard lyric.originalText == original else { return false }
        }
        return translatedLyrics.contains {
            !$0.translatedText.isEmpty
                && $0.translatedText != $0.originalText
                && LyricsLanguage.shouldTranslateRow($0.originalText, targetCode: targetCode)
        }
    }

    /// Keeps stable row identity across translation rebuilds so ScrollView doesn't jump to top.
    func makeTranslatedLyric(
        at index: Int,
        text: String,
        startMs: Int?,
        translatedText: String,
        backgroundTranslation: String = "",
        backgroundBegin: Double? = nil,
        backgroundEnd: Double? = nil,
        pronunciationText: String = "",
        translationSource: TranslationSource = .none
    ) -> TranslatedLyric {
        let preservedID = index < translatedLyrics.count ? translatedLyrics[index].id : UUID()
        let existingPronunciation = index < translatedLyrics.count
            ? translatedLyrics[index].pronunciationText
            : ""
        return TranslatedLyric(
            id: preservedID,
            time: TimeInterval(startMs ?? 0) / 1000,
            originalText: text,
            translatedText: translatedText,
            backgroundTranslation: backgroundTranslation,
            backgroundBegin: backgroundBegin,
            backgroundEnd: backgroundEnd,
            pronunciationText: pronunciationText.isEmpty ? existingPronunciation : pronunciationText,
            isBlank: text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            translationSource: translationSource
        )
    }

    func replaceTranslatedLyrics(_ results: [TranslatedLyric], reveal: Bool = false) {
        let changed = translatedLyrics != results
        let visibilityChanged = reveal && !areTranslationsVisible
        let apply = {
            self.translatedLyrics = results
            if results.contains(where: { !$0.translatedText.isEmpty && $0.translatedText != $0.originalText }) {
                self.translationErrorMessage = nil
            }
            if reveal {
                self.areTranslationsVisible = true
            }
        }
        if reveal && visibilityChanged {
            withAnimation(CassetteAnimation.surface) {
                apply()
            }
        } else {
            apply()
        }
        // Re-center when line heights change from newly revealed translations.
        if changed || visibilityChanged {
            scrollRestoreToken += 1
        }
    }

    /// Always `false` — chorus is rendered inside the same VStack below
    /// translation, so there's no layout shift that would fight the scroll
    /// animation. Auto-scroll never needs to pause.
    var isChorusActive: Bool { false }

    /// True when at least one stored line has a meaningful translation (even if currently hidden).
    var hasStoredTranslation: Bool {
        translatedLyrics.contains {
            !$0.translatedText.isEmpty && $0.translatedText != $0.originalText
        }
    }

    var hasPronunciation: Bool {
        translatedLyrics.contains {
            !$0.pronunciationText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && $0.pronunciationText != $0.originalText
        }
    }

    func togglePronunciationVisibility() {
        guard hasPronunciation else { return }
        withAnimation(CassetteAnimation.surface) {
            arePronunciationsVisible.toggle()
            scrollRestoreToken += 1
        }
    }

    func clearCache() async {
        LyricsTranslationService.shared.clearCache()

        if case .loaded(let structured) = state {
            await seedOriginalLyrics(from: structured, hideTranslations: true)
        }
    }

    /// Hides translated lines without discarding them (allows a smooth fade-out and instant re-show).
    func clearTranslation() {
        translationErrorMessage = nil
        areTranslationsVisible = false
    }

    /// Shows already-fetched translations again.
    func revealTranslation() {
        guard hasStoredTranslation else { return }
        translationErrorMessage = nil
        areTranslationsVisible = true
    }
}
