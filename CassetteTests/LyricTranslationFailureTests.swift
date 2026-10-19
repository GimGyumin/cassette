import Foundation
import Testing
@testable import Cassette

@Suite("Translation recovery presentation") @MainActor
struct LyricTranslationFailureTests {
    @Test func modelRefusalOffersStandardTranslationWithoutRepeatingTheRequest() {
        let failure = LyricTranslationFailure.from(
            AppleIntelligenceLyricsTranslator.TranslationError.contentUnavailable, customPrompt: true)
        #expect(!failure.canRetry)
        #expect(failure.offersStandardTranslation)
        #expect(!failure.message.localizedCaseInsensitiveContains("guardrail"))
    }

    @Test func providerDiagnosticsNeverBecomeUserVisible() {
        let failure = LyricTranslationFailure.from(TranslationError.networkError("private response token=secret"), customPrompt: false)
        #expect(!failure.message.contains("secret"))
        #expect(failure.canRetry)
        #expect(!failure.offersStandardTranslation)
    }

    @Test func credentialsRequireUserActionInsteadOfABlindRetry() {
        let failure = LyricTranslationFailure.from(TranslationError.invalidAPIKey, customPrompt: false)
        #expect(!failure.canRetry)
    }
}
