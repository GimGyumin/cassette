// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation

/// Device / user-chosen UI language for Cassette (Korean when preferred, otherwise English).
nonisolated enum AppLanguage: String, Sendable {
    case english = "en"
    case korean = "ko"

    /// Primary app language: iOS app-specific language first, then Cassette's stored preference.
    static var current: AppLanguage {
        let code = AppUILanguage.locale.language.languageCode?.identifier ?? AppUILanguage.locale.identifier
        return code.hasPrefix("ko") ? .korean : .english
    }

    var code: String { rawValue }

    /// Session instructions when summarizing Wikipedia/MusicBrainz research + lyrics.
    var songResearchSessionInstructions: String {
        switch self {
        case .korean:
            return """
            당신은 음악 앱의 곡 분석 작성기입니다.
            사용자가 제공한 RESEARCH(검색 결과)와 LYRICS(가사), 태그 필드만 근거로 쓰세요.
            RESEARCH에 없는 협업·연도·차트·수상을 지어내지 마세요.
            RESEARCH를 바탕으로 곡을 요약하고, 가사가 있으면 가사를 쉽게 해설하세요.
            JSON·절차 설명 없이 요청한 형식의 산문만 출력하세요.
            """
        case .english:
            return """
            You write song analysis for a music app.
            Use only the provided RESEARCH notes, LYRICS, and tag fields.
            Do not invent collaborations, years, charts, or awards absent from RESEARCH.
            Summarize the song from RESEARCH, then explain the lyrics in plain language when lyrics are present.
            Output only the requested prose — no JSON, no process notes.
            """
        }
    }

    /// User prompt for research-backed song insight.
    var songResearchPromptPrefix: String {
        switch self {
        case .korean:
            return """
            아래 RESEARCH와 LYRICS를 바탕으로 한국어 산문을 쓰세요.

            형식:
            1) 첫 단락: 곡·앨범·아티스트 배경 요약 (3~5문장). RESEARCH에 있는 사실만. 태그 필드로 빠진 이름만 보강.
            2) 단독 줄: ---
            3) 둘째 단락: 가사 의미·감정·비유 해설 (5~8문장). 실제 LYRICS에 나온 내용만.
               LYRICS 블록에 가사가 있으면 반드시 해설하고, 「가사 없음/불러오지 못함」이라고 쓰지 마세요.
               LYRICS가 비어 있을 때만 「가사를 불러오지 못해 가사 해설은 생략합니다.」

            금지: RESEARCH/LYRICS에 없는 사실 창작, JSON, 메타 인사, 긴 가사 인용.
            """
        case .english:
            return """
            Using the RESEARCH and LYRICS below, write English prose:

            Format:
            1) First paragraph: summarize song/album/artist background (3–5 sentences) using RESEARCH facts only. Tags may fill missing names.
            2) A line with only: ---
            3) Second paragraph: lyric meaning/emotion/metaphor (5–8 sentences) grounded in LYRICS.
               When the LYRICS block has lines, you MUST write commentary — never claim lyrics are missing/unavailable.
               Only if LYRICS is empty: "Lyrics could not be loaded, so lyric commentary is skipped."

            Forbidden: inventing facts not in RESEARCH/LYRICS; JSON; meta greetings; long lyric quotes.
            """
        }
    }

    /// Instruction block for on-device AI lyrics summaries / commentary.
    var lyricsSummaryPromptPrefix: String {
        switch self {
        case .korean:
            return """
            역할: 아래에 주어진 가사만 보고 의미를 쉽게 풀어 주는 해설자.
            반드시 지킬 것:
            - 제공된 가사·제목·아티스트에만 근거하세요. 없는 스토리·협업·연도·차트·앨범 비하인드를 만들지 마세요.
            - JSON/마크다운/불릿/메타 인사 금지. 한국어 산문만.
            - 5~8문장. 감정·상황을 요약한 뒤, 가사에 실제로 나온 이미지·비유만 쉬운 말로 설명하세요.
            - 가사에 없는 상징을 지어내지 마세요.
            """
        case .english:
            return """
            Role: explain ONLY the lyrics provided below in plain language.
            Rules:
            - Ground every claim in the given lyrics, title, and artist. Do not invent plot, collaborations, years, charts, or album lore.
            - No JSON/markdown/bullets/meta greetings — English prose only.
            - 5–8 sentences. Summarize emotion/situation, then explain images/metaphors that actually appear in the lyrics.
            - Do not invent symbols that are not in the lyrics.
            """
        }
    }

    /// Prompt for a broader “about this song” blurb (album context, genre, era — not lyrics).
    var songDescriptionPromptPrefix: String {
        switch self {
        case .korean:
            return """
            역할: 아래에 적힌 메타데이터만으로 곡을 짧게 소개하는 안내자.
            반드시 지킬 것:
            - Title/Artist/Album/Genre/Composer에 있는 정보만 쓰세요. 협업, 연도, 차트, 다른 아티스트 이름은 지어내지 마세요.
            - Unknown/비어 있는 필드는 언급하지 마세요.
            - JSON/마크다운/불릿/메타 인사 금지. 한국어 산문 2~3문장만.
            - 가사를 인용하거나 해석하지 마세요.
            """
        case .english:
            return """
            Role: briefly introduce the song using ONLY the metadata fields below.
            Rules:
            - Use only Title/Artist/Album/Genre/Composer. Do not invent collaborations, years, charts, or other artists.
            - Skip any field that is Unknown or empty.
            - No JSON/markdown/bullets/meta greetings — 2–3 English sentences only.
            - Do not quote or interpret lyrics.
            """
        }
    }

    /// Session instructions for grounded Song Info generation (higher priority than the user prompt).
    var songInsightSessionInstructions: String {
        switch self {
        case .korean:
            return """
            당신은 음악 앱의 곡 정보 작성기입니다.
            사용자가 준 필드와 가사에만 근거하세요. 외부 지식으로 사실처럼 보이는 내용을 지어내지 마세요.
            다른 곡·아티스트·협업·연도·차트·수상은 입력에 없으면 절대 언급하지 마세요.
            JSON이나 절차 설명 없이 요청한 형식의 산문만 출력하세요.
            """
        case .english:
            return """
            You write Song Info blurbs for a music app.
            Use only the fields and lyrics the user provides. Do not invent facts from outside knowledge.
            Never mention other songs, artists, collaborations, years, charts, or awards unless they appear in the input.
            Output only the requested prose — no JSON, no process notes.
            """
        }
    }

    /// Combined Song Info AI brief: about + longer lyrics meaning.
    var songInsightPromptPrefix: String {
        switch self {
        case .korean:
            return """
            아래 메타데이터와 가사만 보고 한국어로 쓰세요.

            형식:
            1) 첫 단락: 메타데이터만으로 곡 소개 (2~3문장). 있는 필드만 자연스럽게 연결.
            2) 단독 줄: ---
            3) 둘째 단락: 제공된 가사 기반 해설 (5~8문장). 가사에 나온 감정·이미지·비유만.

            금지: 입력에 없는 협업/연도/차트/다른 아티스트, JSON, 메타 인사, 긴 가사 인용.
            가사가 없으면 둘째 단락에 「가사가 없어 가사 해설은 생략합니다.」만 쓰세요.
            """
        case .english:
            return """
            Using ONLY the metadata and lyrics below, write in English:

            Format:
            1) First paragraph: introduce the song from metadata only (2–3 sentences). Use present fields only.
            2) A line with only: ---
            3) Second paragraph: lyric reading grounded in the provided lyrics (5–8 sentences).

            Forbidden: inventing collaborations/years/charts/other artists; JSON; meta greetings; long lyric quotes.
            If lyrics are missing, second paragraph must be exactly: "No lyrics are loaded, so lyric commentary is skipped."
            """
        }
    }
}

/// User-selectable app UI language (onboarding + `AppleLanguages` override).
nonisolated enum AppUILanguage: String, CaseIterable, Identifiable, Sendable {
    case english = "en"
    case korean = "ko"

    static let storageKey = "cassette.appLanguage"

    static var locale: Locale {
        Locale(identifier: systemPreferredCode ?? storedCode ?? "en")
    }

    private static var systemPreferredCode: String? {
        Bundle.main.preferredLocalizations
            .lazy
            .compactMap { raw -> String? in
                let code = Locale(identifier: raw).language.languageCode?.identifier ?? raw
                return ["en", "ko"].contains(code) ? code : nil
            }
            .first
    }

    private static let languageBundles: [String: Bundle] = {
        var result: [String: Bundle] = [:]
        for code in ["en", "ko"] {
            if let path = Bundle.main.path(forResource: code, ofType: "lproj"), let bundle = Bundle(path: path) {
                result[code] = bundle
            }
        }
        return result
    }()

    static var localizationBundle: Bundle { localizationBundle(for: locale) }

    static func localizationBundle(for locale: Locale) -> Bundle {
        let code = locale.language.languageCode?.identifier ?? "en"
        return languageBundles[code] ?? languageBundles["en"] ?? .main
    }

    var id: String { rawValue }

    /// Native spelling so the picker is readable before localization is applied.
    var displayName: String {
        switch self {
        case .english: return "English"
        case .korean: return "한국어"
        }
    }

    static var storedCode: String? {
        let value = UserDefaults.standard.string(forKey: storageKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    /// Default selection for the onboarding picker.
    static var preferredForPicker: AppUILanguage {
        if let stored = storedCode {
            return AppUILanguage(rawValue: stored) ?? .english
        }
        return AppLanguage.current == .korean ? .korean : .english
    }

    static func select(_ language: AppUILanguage) {
        UserDefaults.standard.set(language.rawValue, forKey: storageKey)
        UserDefaults.standard.set([language.rawValue], forKey: "AppleLanguages")
    }
}

/// Script heuristics for partial lyrics translation.
nonisolated enum LyricsLanguage: Sendable {
    /// Normalize language tags from Settings pickers / server metadata.
    /// Kept here (not on `LyricsTranslationSettings`) so nonisolated call sites stay Swift 6–safe.
    static func normalizedLanguageCode(_ raw: String?) -> String {
        let value = (raw ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch value {
        case "", "auto", "xxx", "unknown", "null":
            return "ko"
        case "kor", "ko":
            return "ko"
        case "eng", "en":
            return "en"
        case "jpn", "ja":
            return "ja"
        case "zho", "zh", "cn", "zh-hans", "zh-hant":
            return "zh"
        case "spa", "es":
            return "es"
        case "fra", "fr":
            return "fr"
        default:
            return value
        }
    }

    /// Whether a lyric line should be sent to / shown as a translation into `targetCode`.
    static func shouldTranslateRow(_ text: String, targetCode: String) -> Bool {
        let target = Self.normalizedLanguageCode(targetCode)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || Double(trimmed) != nil { return false }

        switch target {
        case "ko":
            return text.range(of: "\\p{Hangul}", options: .regularExpression) == nil
        case "en":
            // Mostly Latin letters already → skip.
            let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
            guard !letters.isEmpty else { return true }
            let latin = letters.filter { CharacterSet(charactersIn: "A"..."Z").contains($0) || CharacterSet(charactersIn: "a"..."z").contains($0) }
            return Double(latin.count) / Double(letters.count) < 0.6
        case "ja":
            return text.range(of: "[\\p{Hiragana}\\p{Katakana}]", options: .regularExpression) == nil
        case "zh":
            return text.range(of: "\\p{Han}", options: .regularExpression) == nil
        default:
            return true
        }
    }

    /// True when at least one non-blank line still needs translation into the target.
    static func needsTranslation(lines: [String], targetCode: String) -> Bool {
        lines.contains { shouldTranslateRow($0, targetCode: targetCode) }
    }

    static func resolvedSourceLanguage(from structuredLang: String?) -> String {
        let raw = structuredLang ?? "en"
        if raw.isEmpty || ["xxx", "unknown", "null", "auto", "und"].contains(raw.lowercased()) {
            return "en"
        }
        return normalizedLanguageCode(raw)
    }
}
