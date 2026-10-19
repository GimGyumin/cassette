import Foundation

/// Only known, localized application messages reach the lyrics surface. Provider diagnostics
/// may contain internal model text or response bodies and are kept out of the UI.
struct LyricTranslationFailure {
    let message: String
    let canRetry: Bool
    let offersStandardTranslation: Bool

    static func from(_ error: Error, customPrompt: Bool) -> Self {
        if let failure = error as? AppleIntelligenceLyricsTranslator.TranslationError {
            let canRetry: Bool
            switch failure {
            case .busy, .invalidResponse: canRetry = true
            case .unavailable, .promptTooLong, .contextLimit, .unsupportedLanguage, .contentUnavailable: canRetry = false
            }
            return Self(message: failure.localizedDescription, canRetry: canRetry,
                        offersStandardTranslation: customPrompt && !canRetry)
        }
        if let failure = error as? TranslationError {
            switch failure {
            case .invalidAPIKey, .billingInactive:
                return Self(message: failure.localizedDescription, canRetry: false, offersStandardTranslation: false)
            case .rateLimited:
                return Self(message: failure.localizedDescription, canRetry: true, offersStandardTranslation: false)
            default: break
            }
        }
        return Self(message: String(localized: "Translation is temporarily unavailable. Your original lyrics are still available.",
                    bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
                    canRetry: true, offersStandardTranslation: false)
    }
}
