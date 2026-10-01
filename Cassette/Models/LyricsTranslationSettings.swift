// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import Combine

enum TranslationProvider: String, CaseIterable, Identifiable {
    case apple = "Apple Translation"
    case openAI = "OpenAI Translation"

    var id: String { self.rawValue }

    var displayName: String {
        switch self {
        case .apple: return String(localized: "Apple Translation", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        case .openAI: return String(localized: "OpenAI Translation", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        }
    }
}

final class LyricsTranslationSettings: ObservableObject {
    static let shared = LyricsTranslationSettings()

    private let defaults = UserDefaults.standard

    @Published var isTranslationEnabled: Bool {
        didSet { defaults.set(isTranslationEnabled, forKey: "isTranslationEnabled") }
    }

    @Published var isAutoTranslateEnabled: Bool {
        didSet { defaults.set(isAutoTranslateEnabled, forKey: "isAutoTranslateEnabled") }
    }

    @Published var provider: TranslationProvider {
        didSet { defaults.set(provider.rawValue, forKey: "translationProvider") }
    }

    @Published var targetLanguage: String {
        didSet { defaults.set(targetLanguage, forKey: "targetLanguage") }
    }

    @Published var openAIAPIKey: String {
        didSet {
            let trimmed = openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed != openAIAPIKey {
                openAIAPIKey = trimmed
                return
            }
            SensitiveSettingsStore.set(openAIAPIKey, forKey: Self.openAIAPIKeyKey)
        }
    }

    @Published var lyricsSource: LyricsSourcePreference {
        didSet { defaults.set(lyricsSource.rawValue, forKey: LyricsSourcePreference.userDefaultsKey) }
    }

    /// Call once at launch so stored preference keys resolve before the first read.
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            "isTranslationEnabled": true,
            "isAutoTranslateEnabled": false,
            "translationProvider": TranslationProvider.apple.rawValue,
            "targetLanguage": "ko",
            LyricsSourcePreference.userDefaultsKey: LyricsSourcePreference.default.rawValue,
            "cassette.streaming.wifi": "matchStream",
            "cassette.streaming.cellular": "mp3_192",
            "cassette.cache.format": "matchStream",
            "cassette.cache.cellular": false,
            "cassette.cache.maxMegabytes": 2048,
            "cassette.download.automaticOverCellular": false,
            "cassette.lyrics.largerText": "lyrics",
            "cassette.visuals.animatedArtwork": true,
            "cassette.history.enabled": true,
        ])
        ReplayGainSettings.registerDefaults()
        CrossfadeSettings.registerDefaults()
    }

    /// Normalize language tags coming from Settings pickers / server metadata.
    nonisolated static func normalizedLanguageCode(_ raw: String?) -> String {
        LyricsLanguage.normalizedLanguageCode(raw)
    }

    /// Apple Translation hangs when source == target. Prefer a useful fallback (ko for English lyrics).
    nonisolated static func resolvedTargetLanguage(preferred: String, source: String) -> String {
        let sourceCode = LyricsLanguage.normalizedLanguageCode(source)
        let target = LyricsLanguage.normalizedLanguageCode(preferred)
        if target != sourceCode { return target }

        if sourceCode == "en" { return "ko" }
        if sourceCode == "ko" { return "en" }
        return sourceCode == "ja" ? "en" : "ko"
    }

    private init() {
        Self.registerDefaults()

        // Settings toggles write through UserDefaults; refresh in-memory values on foreground.
        self.isTranslationEnabled = defaults.object(forKey: "isTranslationEnabled") as? Bool ?? true
        self.isAutoTranslateEnabled = defaults.bool(forKey: "isAutoTranslateEnabled")

        if let providerString = defaults.string(forKey: "translationProvider"),
           let savedProvider = TranslationProvider(rawValue: providerString) {
            self.provider = savedProvider
        } else {
            self.provider = .apple
        }

        // Prefer Korean for first launch / empty values. One-time migrate "en" when device UI is Korean
        // (legacy Settings text field / defaults often left English lyrics translating en→en forever).
        let storedTarget = defaults.string(forKey: "targetLanguage")
        let prefersKorean = Locale.preferredLanguages.first?.lowercased().hasPrefix("ko") == true
        if storedTarget == nil || storedTarget?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            self.targetLanguage = "ko"
            defaults.set("ko", forKey: "targetLanguage")
        } else if prefersKorean,
                  Self.normalizedLanguageCode(storedTarget) == "en",
                  defaults.bool(forKey: "cassette.didMigrateTargetLanguageToKo") == false {
            self.targetLanguage = "ko"
            defaults.set("ko", forKey: "targetLanguage")
            defaults.set(true, forKey: "cassette.didMigrateTargetLanguageToKo")
        } else {
            self.targetLanguage = Self.normalizedLanguageCode(storedTarget)
        }
        self.openAIAPIKey = SensitiveSettingsStore
            .migratedString(forKey: Self.openAIAPIKeyKey, defaults: defaults)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.lyricsSource = LyricsSourcePreference.current(from: defaults)

        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: defaults,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reloadFromDefaults()
            }
        }
    }

    /// Re-read values written by Settings.app when the app becomes active again.
    /// Defaults notifications may be coalesced while the process is suspended.
    func reloadFromDefaults() {
        let enabled = defaults.object(forKey: "isTranslationEnabled") as? Bool ?? true
        if isTranslationEnabled != enabled { isTranslationEnabled = enabled }

        let auto = defaults.bool(forKey: "isAutoTranslateEnabled")
        if isAutoTranslateEnabled != auto { isAutoTranslateEnabled = auto }

        let target = Self.normalizedLanguageCode(defaults.string(forKey: "targetLanguage"))
        if targetLanguage != target { targetLanguage = target }

        if let providerString = defaults.string(forKey: "translationProvider"),
           let savedProvider = TranslationProvider(rawValue: providerString),
           provider != savedProvider {
            provider = savedProvider
        }

        let source = LyricsSourcePreference.current(from: defaults)
        if lyricsSource != source { lyricsSource = source }
    }

    nonisolated static let openAIAPIKeyKey = "openAIAPIKey"
}
