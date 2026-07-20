// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

struct TranslationSettingsView: View {
    @StateObject private var settings = LyricsTranslationSettings.shared
    
    private let languages = [
        ("ko", "한국어 (Korean)"),
        ("en", "English (English)"),
        ("ja", "日本語 (Japanese)"),
        ("zh", "简体中文 (Simplified Chinese)"),
        ("es", "Español (Spanish)"),
        ("fr", "Français (French)")
    ]
    
    var body: some View {
        Section(header: Text("가사 번역 (Lyrics Translation)")) {
            Toggle("실시간 번역 활성화", isOn: $settings.isTranslationEnabled)
                .tint(.blue)
            
            if settings.isTranslationEnabled {
                Picker("번역 엔진 선택", selection: $settings.provider) {
                    ForEach(TranslationProvider.allCases) { provider in
                        Text(provider.rawValue).tag(provider)
                    }
                }
                .pickerStyle(.menu)
                
                Picker("번역 목표 언어", selection: $settings.targetLanguage) {
                    ForEach(languages, id: \.0) { code, name in
                        Text(name).tag(code)
                    }
                }
                .pickerStyle(.menu)
                
                Toggle("곡 시작 시 자동 번역", isOn: $settings.isAutoTranslateEnabled)
                    .tint(.blue)
                
                if settings.provider == .openAI {
                    SecureField("OpenAI API Key 입력", text: $settings.openAIAPIKey)
                        .disableAutocorrection(true)
                }
                
                Button(role: .destructive, action: {
                    TranslationCache.shared.clear()
                }) {
                    HStack {
                        Image(systemName: "trash")
                        Text("번역 로컬 캐시 전체 삭제")
                    }
                }
            }
        }
    }
}
