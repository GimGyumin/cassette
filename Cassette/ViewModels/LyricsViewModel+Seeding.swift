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
    /// Seeds the lyric list used by the UI. Never leave `translatedLyrics` empty while loaded.
    /// Preserves existing translations when source lines still match.
    func seedOriginalLyrics(
        from structured: StructuredLyrics,
        hideTranslations: Bool
    ) async {
        if hideTranslations {
            areTranslationsVisible = false
        }

        // Phase D: TTML parsing + display-row adaptation run OFF the MainActor —
        // synchronous SAX + row building is CPU-bound and blocks SwiftUI ticks.
        let ttmlData = rawTTMLData
        documentBuildGeneration &+= 1
        let generation = documentBuildGeneration
        let preferredLanguages = [LyricsTranslationSettings.shared.targetLanguage] + Locale.preferredLanguages
        let parsed: (document: LyricDocument?, rows: [LyricDisplayRow]) = await Task.detached(priority: .userInitiated) {
            var document = LyricDocumentBuilder.build(preferringTTML: ttmlData, structured: structured)
            document?.selectTranslation(preferredLanguages: preferredLanguages)
            let rows = document.map { LyricDisplayBuilder.rows(from: $0) } ?? []
            return (document, rows)
        }.value

        guard generation == documentBuildGeneration, !Task.isCancelled else { return }
        lyricDocument = parsed.document
        displayRows = parsed.rows
        let documentLines = parsed.document?.allLines ?? []
        pronunciationRows = documentLines.map { line in
            guard let key = line.key, let pronunciation = parsed.document?.pronunciation(for: key) else { return [] }
            return pronunciation.words.map {
                LyricDisplayWord(text: $0.text, startMs: LyricTime.milliseconds(fromSeconds: $0.begin),
                    endMs: LyricTime.milliseconds(fromSeconds: $0.end), role: $0.role, preservesSourceSpacing: true)
            }
        }
        rebuildInstrumentalGapCache()

        let pronunciationLines: [Line]
        if let list = lyricsList,
           let pronunciation = LyricsLayerAligner.pronunciation(for: structured, in: list) {
            pronunciationLines = pronunciation.line
        } else {
            pronunciationLines = []
        }
        let pronunciations = LyricsLayerAligner.align(primary: structured.line, secondary: pronunciationLines)

        var serverTranslations: [String] = Array(repeating: "", count: structured.line.count)
        if let lang = selectedServerTranslationLang,
           let list = lyricsList,
           let track = LyricsLayerAligner.translationTracks(in: list)
            .first(where: { LyricsLayerAligner.normalize($0.lang) == lang }) {
            serverTranslations = LyricsLayerAligner.align(primary: structured.line, secondary: track.line)
        }

        let ttmlTranslations = lyricDocument?.translatedLines ?? []
        let hasTtmlTranslation = !ttmlTranslations.isEmpty
        if hasTtmlTranslation {
            print("Loaded Apple Music embedded translations: \(ttmlTranslations.filter { !$0.isEmpty }.count) lines")
        }

        let results = displayRows.enumerated().map { displayIndex, row -> TranslatedLyric in
            let sourceIndex = row.sourceLineIndex
            let existing = displayIndex < translatedLyrics.count ? translatedLyrics[displayIndex] : nil
            let serverText = sourceIndex < serverTranslations.count ? serverTranslations[sourceIndex] : ""
            // Require: `<text for="L15">` maps ONLY to `<p itunes:key="L15">`.
            // Display rows track the same document order as `lyricDocument.allLines`,
            // so the key lookup at displayIndex is the line's own key — never a neighbor's.
            let lineKey = displayIndex < documentLines.count
                ? documentLines[displayIndex].key
                : nil
            let ttmlTranslation = lineKey.flatMap { lyricDocument?.translations[$0] }
            // The parser separates x-bg structurally — main and background are never merged.
            let ttmlText = ttmlTranslation?.main ?? ""
            let rawTtmlBg = ttmlTranslation?.background ?? ""
            // Cross-validate: if the original English body line has no x-bg
            // words, suppress the translation's phantom x-bg (Apple data error).
            // displayRows are built from the same TTML body, so backgroundWords
            // directly reflects whether this line actually has backing vocals.
            // Cross-validate: the body line must actually contain x-bg words
            // for the translation's background to be genuine. Server translation
            // tracks always have empty backgroundWords in displayRows, so use
            // the authoritative source: LyricDocument.bodyLineKeysWithBackground.
            let bodyHasBackground = lyricDocument?.bodyLineKeysWithBackground.contains(lineKey ?? "") == true
            || !displayRows[displayIndex].backgroundWords.isEmpty
            let shouldSuppressBg = false
            let ttmlBg = rawTtmlBg
            let ttmlBgBegin: TimeInterval? = ttmlTranslation?.backgroundBegin
            let ttmlBgEnd: TimeInterval? = ttmlTranslation?.backgroundEnd
            let ttmlTextAdjusted = ttmlText
            if let key = lineKey, !rawTtmlBg.isEmpty {
                print("[X-BG DEBUG] \(key) bodyHasBg=\(bodyHasBackground) suppress=\(shouldSuppressBg) bg=\"\(rawTtmlBg.prefix(30))...\"")
            }
            // Secondary agents (chorus) keep their own text — don't paste lead translations.
            let keepClient = !row.isSecondaryAgent && existing?.originalText == row.text
                ? (existing?.translatedText ?? "")
                : ""
            // Server translation may have chorus text in parentheses.
            // Split it out so the chorus translation renders BELOW the main
            // translation (like TTML x-bg) instead of being merged into one string.
            let rawServerText = serverText
            let serverSplit = Self.extractParenthesizedChorus(from: rawServerText)
            let strippedServerText = serverSplit.main
            let serverChorusText = serverSplit.chorus
            let translated = row.isSecondaryAgent
                ? ""
                : (!ttmlTextAdjusted.isEmpty ? ttmlTextAdjusted : (!strippedServerText.isEmpty ? strippedServerText : keepClient))
            // TTML translation: use parsed x-bg. Server translation: use extracted parenthesized chorus.
            let bg: String
            if !ttmlTextAdjusted.isEmpty {
                bg = row.isSecondaryAgent ? "" : ttmlBg
            } else {
                bg = row.isSecondaryAgent ? "" : serverChorusText
            }
            let embeddedPronunciation = lineKey.flatMap { lyricDocument?.pronunciation(for: $0) }
            let pronunciation = embeddedPronunciation.map { row.isSecondaryAgent ? $0.background : $0.main }
                ?? ((!row.isSecondaryAgent && sourceIndex < pronunciations.count) ? pronunciations[sourceIndex] : "")
            let source: TranslationSource = !ttmlText.isEmpty ? .ttml
                : (!serverText.isEmpty ? .server : existing?.translationSource ?? .none)
            // Secondary background-only rows have empty `row.text` (mainWords == "").
            // Use background words as the display text so the chorus shows.
            let text = row.isSecondaryAgent && row.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !row.backgroundWords.isEmpty
                ? LyricKaraokeText.chorusText(from: row.backgroundWords)
                : row.text

            return makeTranslatedLyric(
                at: displayIndex,
                text: text,
                startMs: row.startMs,
                translatedText: translated,
                backgroundTranslation: bg,
                backgroundBegin: ttmlBgBegin,
                backgroundEnd: ttmlBgEnd,
                pronunciationText: pronunciation,
                translationSource: source
            )
        }
        let bgChanged = results.map(\.backgroundTranslation) != translatedLyrics.map(\.backgroundTranslation)
        let originalsChanged = results.map(\.originalText) != translatedLyrics.map(\.originalText)
            || results.map(\.pronunciationText) != translatedLyrics.map(\.pronunciationText)
            || results.count != translatedLyrics.count
            || bgChanged
        // Always apply when background translations have been suppressed
        // (cross-validation removed phantom x-bg from Apple data).
        if originalsChanged || bgChanged {
            replaceTranslatedLyrics(results)
        } else if hideTranslations {
            areTranslationsVisible = false
        } else if translatedLyrics.isEmpty {
            replaceTranslatedLyrics(results)
        }

        // Don't auto-show — let the toggle button control visibility.
    }

    /// Prefer a server `kind=translation` track over client machine translation.
    // MARK: Helpers

    func applyCurrentLanguage() async {

        guard let list = lyricsList
        else {
            return
        }

        // Track change: discard all cached translations and chorus data from the
        // previous song so they never leak into the new display rows (Bug E).
        translatedLyrics = []
        areTranslationsVisible = false

        var seen = Set<String>()


        availableLanguages =
        list.structuredLyrics
            .filter(\.isPrimaryLayer)
            .compactMap {
                $0.lang
            }
            .filter {
                seen.insert($0).inserted
            }

        availableServerTranslations = LyricsLayerAligner.translationTracks(in: list).compactMap { track in
            guard let lang = LyricsLayerAligner.normalize(track.lang) else { return nil }
            let title = Locale.current.localizedString(forLanguageCode: lang) ?? lang.uppercased()
            return (lang: lang, title: title)
        }
        // Dedupe by lang
        var seenTranslation = Set<String>()
        availableServerTranslations = availableServerTranslations.filter { seenTranslation.insert($0.lang).inserted }



        let best =
        lyricsService.selectBestLanguage(
            from: list,
            preferred: selectedLanguage
        )


        clearLineHighlight()


        state =
        best.map {
            .loaded($0)
        }
        ?? .empty



        if let structured = best {
            // Auto-select a matching server translation track if available.
            if selectedServerTranslationLang == nil {
                let targetLang = LyricsTranslationSettings.normalizedLanguageCode(LyricsTranslationSettings.shared.targetLanguage).lowercased()
                // Match exact or prefix (e.g. "ko" matches "ko-kr", "ko_kr", "ko")
                let match = availableServerTranslations.first { track in
                    let trackLang = track.lang.lowercased()
                    return trackLang == targetLang || trackLang.replacingOccurrences(of: "-", with: "_") == targetLang
                        || (trackLang.hasPrefix(targetLang) && (trackLang.dropFirst(targetLang.count).first == "-" || trackLang.dropFirst(targetLang.count).first == "_"))
                }
                if let match {
                    selectedServerTranslationLang = match.lang
                    print("📖 Auto-selected server translation: \(match.lang)")
                } else {
                    print("📖 No matching server translation for target '\(targetLang)'. Available: \(availableServerTranslations.map { $0.lang })")
                }
            }
            // Always paint originals first, preserving translation visibility state.
            let wasTranslationVisible = areTranslationsVisible
            let hasExistingTranslations = translatedLyrics.contains(where: { !$0.translatedText.isEmpty && $0.translatedText != $0.originalText })
            await seedOriginalLyrics(from: structured, hideTranslations: false)
            // Restore visibility when translations were previously shown.
            if wasTranslationVisible && hasExistingTranslations {
                areTranslationsVisible = true
            }

            let settings = LyricsTranslationSettings.shared
            guard settings.isTranslationEnabled else {
                reconcileTracking()
                return
            }

            // Already have meaningful translations — keep current visibility, just show button.
            if selectedServerTranslationLang != nil || translatedLyrics.contains(where: { !$0.translatedText.isEmpty && $0.translatedText != $0.originalText }) {
                reconcileTracking()
                return
            }

            let resolvedSource = LyricsLanguage.resolvedSourceLanguage(from: structured.lang)
            let preferredTarget = LyricsTranslationSettings.normalizedLanguageCode(settings.targetLanguage)
            let finalTarget = preferredTarget == resolvedSource && LyricsLanguage.needsTranslation(lines: structured.line.map(\.value), targetCode: preferredTarget)
                ? preferredTarget
                : LyricsTranslationSettings.resolvedTargetLanguage(preferred: preferredTarget, source: resolvedSource)
            let originalLines = displayRows.map(\.text)

            if let cached = TranslationCache.shared.get(
                songID: songId,
                sourceLang: resolvedSource,
                targetLang: finalTarget,
                provider: settings.provider,
                originalLines: originalLines
            ) {
                replaceTranslatedLyrics(cached, reveal: settings.isAutoTranslateEnabled)
                reconcileTracking()
                return
            }

            if structured.synced, settings.isAutoTranslateEnabled {
                Task { await translateCurrentLyrics() }
            }
        }


        reconcileTracking()
    }



    func networkErrorMessage(
        from error: LyricsError
    ) -> String {


        if case .networkError(let msg) = error {

            return msg
        }


        return error.localizedDescription
    }
}
