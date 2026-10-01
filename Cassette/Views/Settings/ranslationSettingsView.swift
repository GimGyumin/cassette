// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

struct TranslationSettingsView: View {
    @StateObject private var settings = LyricsTranslationSettings.shared
    
    private let languageCodes = ["ko", "en", "ja", "zh", "es", "fr"]

    private func languageLabel(_ code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code)?.capitalized ?? code
    }
    
    var body: some View {
        Section(header: Text(String(localized: "Lyrics", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))) {
            Picker(selection: $settings.lyricsSource) {
                ForEach(LyricsSourcePreference.allCases) { source in
                    Text(source.title).tag(source)
                }
            } label: {
                SettingsRowLabel(title: "Lyrics Source", systemImage: "text.quote", color: .pink)
            }
            .pickerStyle(.menu)

            Text(settings.lyricsSource.detail)
                .font(.footnote)
                .foregroundStyle(.secondary)

            Toggle(isOn: $settings.isTranslationEnabled) {
                SettingsRowLabel(title: "Enable live translation", systemImage: "character.bubble.fill", color: .teal)
            }
            
            if settings.isTranslationEnabled {
                Picker(selection: $settings.provider) {
                    ForEach(TranslationProvider.allCases) { provider in
                        Text(provider.rawValue).tag(provider)
                    }
                } label: {
                    SettingsRowLabel(title: "Translation Provider", systemImage: "cpu.fill", color: .gray)
                }
                .pickerStyle(.menu)
                
                Picker(selection: $settings.targetLanguage) {
                    ForEach(languageCodes, id: \.self) { code in
                        Text(languageLabel(code)).tag(code)
                    }
                } label: {
                    SettingsRowLabel(title: "Target Language", systemImage: "globe", color: .blue)
                }
                .pickerStyle(.menu)
                
                Toggle(isOn: $settings.isAutoTranslateEnabled) {
                    SettingsRowLabel(title: "Auto-Translate on Load", systemImage: "wand.and.stars", color: .orange)
                }
                
                if settings.provider == .openAI {
                    SettingsTextFieldRow(title: "OpenAI API Key", systemImage: "key.fill", color: .orange) {
                        SecureField(String(localized: "OpenAI API Key", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), text: $settings.openAIAPIKey)
                            .disableAutocorrection(true)
                    }

                    Text("When OpenAI Translation is selected, lyric text is sent to OpenAI. OpenAI may retain API inputs and outputs for up to 30 days for abuse monitoring. Your API key is stored in Keychain, and translated lyrics are cached on this device.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                
                Button(role: .destructive, action: {
                    TranslationCache.shared.clear()
                }) {
                    SettingsRowLabel(title: "Clear translation cache", systemImage: "trash.fill", color: .red)
                }
            }
        }
    }
}
