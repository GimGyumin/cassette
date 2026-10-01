import Foundation
import Testing
@testable import Cassette

@Suite("App localization")
struct AppLocalizationTests {
    @Test("Explicit app languages resolve independently of the device language")
    func languageResources() {
        let english = Locale(identifier: "en")
        let korean = Locale(identifier: "ko")
        #expect(String(localized: "Review Onboarding", bundle: AppUILanguage.localizationBundle(for: english), locale: english) == "Review Onboarding")
        #expect(String(localized: "Review Onboarding", bundle: AppUILanguage.localizationBundle(for: korean), locale: korean) == "온보딩 다시 보기")
        #expect(String(localized: "Use server defaults", bundle: AppUILanguage.localizationBundle(for: english), locale: english) == "Use server defaults")
        #expect(String(localized: "Use server defaults", bundle: AppUILanguage.localizationBundle(for: korean), locale: korean) == "서버 기본 설정 사용")
    }
}
