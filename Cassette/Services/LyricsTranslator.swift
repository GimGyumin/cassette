import Foundation

protocol LyricsTranslator {
    func translate(lyrics: [String], sourceLanguage: String, targetLanguage: String) async throws -> [String]
}

enum TranslationError: LocalizedError {
    case invalidAPIKey
    case billingInactive
    case rateLimited
    case networkError(String)
    case parsingError
    case lineCountMismatch(expected: Int, actual: Int)

    var errorDescription: String? {
        switch self {
        case .invalidAPIKey:
            return String(localized: "OpenAI API key is invalid or empty.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        case .billingInactive:
            return String(localized: "OpenAI billing is inactive. Add a payment method at platform.openai.com.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        case .rateLimited:
            return String(localized: "OpenAI rate limit reached. Try again in a moment.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        case .networkError(let msg):
            return String(localized: "Network error: \(msg)", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        case .parsingError:
            return String(localized: "Failed to parse translation results.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        case .lineCountMismatch(let exp, let act):
            return String(localized: "Line count mismatch: original lyrics (\(exp) lines) vs translation (\(act) lines).", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        }
    }
}
