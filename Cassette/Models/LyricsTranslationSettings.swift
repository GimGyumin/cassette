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
        didSet { defaults.set(openAIAPIKey, forKey: "openAIAPIKey") }
    }
    
    private init() {
        self.isTranslationEnabled = defaults.bool(forKey: "isTranslationEnabled")
        self.isAutoTranslateEnabled = defaults.bool(forKey: "isAutoTranslateEnabled")
        
        if let providerString = defaults.string(forKey: "translationProvider"),
           let savedProvider = TranslationProvider(rawValue: providerString) {
            self.provider = savedProvider
        } else {
            self.provider = .apple
        }
        
        self.targetLanguage = defaults.string(forKey: "targetLanguage") ?? "ko"
        self.openAIAPIKey = defaults.string(forKey: "openAIAPIKey") ?? ""
    }
}
