// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

extension LyricsSourcePreference: SettingsChoiceItem {
    var choiceTitle: String { title }
    var choiceSubtitle: String? { detail }
}

extension TranslationProvider: SettingsChoiceItem {
    var choiceTitle: String { displayName }
}

extension TranslationStrategyPreference: SettingsChoiceItem {
    var choiceTitle: String { displayName }

    var choiceSubtitle: String? {
        switch self {
        case .automatic:
            return String(localized: "Prefer high quality and fall back automatically.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        case .highFidelity:
            return String(localized: "Prefer Apple Intelligence when supported.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        case .lowLatency:
            return String(localized: "Prioritize faster on-device translation.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        case .standard:
            return String(localized: "Use the default Apple Translation strategy.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        }
    }
}

/// Lyrics, translation, and the translation cache — one card per concern,
/// with translation details disclosed only while translation is on.
/// Standalone screen used by the in-app settings list (and macOS sheets).
struct LyricsSettingsView: View {
    var body: some View {
        Form {
            LyricsSettingsSections()
        }
        .formStyle(.grouped)
        .modifier(SettingsSubpageStyle())
        .navigationTitle(Text("Lyrics & Translation"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

/// Section-level content, also embedded directly in the macOS Settings window.
struct LyricsSettingsSections: View {
    @ObservedObject private var settings = LyricsTranslationSettings.shared
    @AppStorage("cassette.lyrics.largerText") private var largerLyricsText = "lyrics"

    private static let languageCodes = ["ko", "en", "ja", "zh", "es", "fr"]

    var body: some View {
        lyricsSection
        translationSection
        dataSection
    }

    // MARK: - 가사

    private var lyricsSection: some View {
        Section {
            SettingsNavigationRow("Lyrics Source", value: settings.lyricsSource.title) {
                SettingsChoiceList(
                    navigationTitle: "Lyrics Source",
                    items: LyricsSourcePreference.allCases,
                    selection: $settings.lyricsSource
                )
            }

            SettingsNavigationRow("Lyrics Text Size", value: textSize.choiceTitle) {
                SettingsChoiceList(
                    navigationTitle: "Lyrics Text Size",
                    items: LyricsTextSize.allCases,
                    selection: Binding(
                        get: { textSize },
                        set: { largerLyricsText = $0.rawValue }
                    )
                )
            }
        } header: {
            SettingsSectionHeader("Lyrics")
        }
    }

    // MARK: - 번역

    private var translationSection: some View {
        Section {
            Toggle(isOn: $settings.isTranslationEnabled) {
                SettingsRowTitle("Translate Lyrics")
            }

            if settings.isTranslationEnabled {
                SettingsNavigationRow("Translation Engine", value: settings.provider.displayName) {
                    SettingsChoiceList(
                        navigationTitle: "Translation Engine",
                        items: TranslationProvider.allCases,
                        selection: $settings.provider
                    )
                }

                if settings.provider == .apple {
                    SettingsNavigationRow("Translation Strategy", value: settings.strategyPreference.displayName) {
                        SettingsChoiceList(
                            navigationTitle: "Translation Strategy",
                            items: TranslationStrategyPreference.allCases,
                            selection: $settings.strategyPreference
                        )
                    }
                }

                SettingsNavigationRow("Translation Language", value: targetLanguageName) {
                    SettingsChoiceList(
                        navigationTitle: "Translation Language",
                        items: Self.languageCodes.map(LanguageChoice.init(code:)),
                        selection: Binding(
                            get: { LanguageChoice(code: settings.targetLanguage) },
                            set: { settings.targetLanguage = $0.code }
                        )
                    )
                }

                Toggle(isOn: $settings.isAutoTranslateEnabled) {
                    SettingsRowTitle("Auto-Translate on Load")
                }

                if settings.provider == .openAI {
                    SettingsTextFieldRow(title: "OpenAI API Key", systemImage: "key.fill", color: .orange) {
                        SecureField("OpenAI API Key", text: $settings.openAIAPIKey)
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            .textContentType(.password)
                            #endif
                            .disableAutocorrection(true)
                    }
                }
            }
        } header: {
            SettingsSectionHeader("Translation")
        } footer: {
            if settings.provider == .openAI && settings.isTranslationEnabled {
                SettingsSectionFooter("Lyric text is sent to OpenAI, which may retain inputs for up to 30 days. Your API key is stored in the Keychain and translations are cached on this device.")
            } else {
                SettingsSectionFooter("Apple Translation processes supported translations on device. Translated lyrics are cached on this device.")
            }
        }
    }

    // MARK: - 데이터

    private var dataSection: some View {
        Section {
            SettingsActionRow("Clear Translation Cache", isDestructive: true) {
                TranslationCache.shared.clear()
            }
        } header: {
            SettingsSectionHeader("Data")
        }
    }

    // MARK: - Helpers

    private var textSize: LyricsTextSize {
        LyricsTextSize(rawValue: largerLyricsText) ?? .lyrics
    }

    private var targetLanguageName: String {
        Locale.current.localizedString(forLanguageCode: settings.targetLanguage)?.capitalized
            ?? settings.targetLanguage
    }

    private enum LyricsTextSize: String, CaseIterable, SettingsChoiceItem {
        case lyrics
        case pronunciation

        var choiceTitle: String {
            self == .pronunciation
                ? String(localized: "Pronunciation", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
                : String(localized: "Lyrics", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        }
    }

    private struct LanguageChoice: SettingsChoiceItem {
        let code: String

        var choiceTitle: String {
            Locale.current.localizedString(forLanguageCode: code)?.capitalized ?? code
        }
    }
}
