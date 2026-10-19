import XCTest

/// Uses a loopback fixture, actual sign-in/search/download services and the native UI.
/// Start ci_scripts/ui_fixture_server.py before running this test (CI does this automatically).
#if os(iOS)
final class ListeningJourneyUITests: XCTestCase {
    @MainActor
    func testSignInSearchDownloadAndPlayWithoutServer() async throws {
        let baseURL = URL(string: "http://127.0.0.1:18765")!
        try await control("__reset", baseURL: baseURL)
        let app = XCUIApplication()
        app.launchArguments = ["--cassette-ui-testing", "--cassette-reset-onboarding",
            "-cassette.appLanguage", "en", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-cassette.streaming.download", "matchStream", "-isAutoTranslateEnabled", "NO"]
        app.launch()
        let language = app.buttons["onboarding.language.continue"]
        XCTAssertTrue(language.waitForExistence(timeout: 20))
        language.tap()
        let url = app.textFields["onboarding.server.url"]
        XCTAssertTrue(url.waitForExistence(timeout: 10))
        url.tap()
        url.typeText(baseURL.absoluteString)
        app.buttons["onboarding.server.continue"].tap()
        let username = app.textFields["onboarding.server.username"]
        XCTAssertTrue(username.waitForExistence(timeout: 10))
        username.tap()
        username.typeText("fixture")
        let password = app.secureTextFields["onboarding.server.password"]
        password.tap()
        password.typeText("fixture")
        app.buttons["onboarding.server.continue"].tap()
        let warning = app.buttons["Continue Anyway"]
        if warning.waitForExistence(timeout: 2) { warning.tap() }
        let about = app.buttons["onboarding.about.continue"]
        XCTAssertTrue(about.waitForExistence(timeout: 20))
        about.tap()
        app.buttons["onboarding.welcome.start"].tap()

        let searchTab = app.tabBars.buttons["Search"]
        XCTAssertTrue(searchTab.waitForExistence(timeout: 15))
        searchTab.tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        search.typeText("Cassette Fixture\n")
        let track = app.buttons["search.song.play.fixture-track"]
        XCTAssertTrue(track.waitForExistence(timeout: 15))
        track.tap()
        let pause = app.buttons["Pause"].firstMatch
        XCTAssertTrue(pause.waitForExistence(timeout: 15))
        await fulfillment(of: [expectation(for: NSPredicate(format: "value == 'Playing'"), evaluatedWith: pause)], timeout: 15)
        pause.tap()
        app.buttons["search.song.more.fixture-track"].tap()
        app.buttons["search.song.download.fixture-track"].tap()
        // Wait for the actual completed-download state, not just a dispatched action.
        let downloaded = app.buttons["search.song.more.fixture-track"]
        let completed = NSPredicate(format: "value == 'Downloaded'")
        await fulfillment(of: [expectation(for: completed, evaluatedWith: downloaded)], timeout: 30)

        try await control("__offline", baseURL: baseURL)
        let before = try await mediaRequests(baseURL)
        track.tap()
        XCTAssertTrue(pause.waitForExistence(timeout: 15))
        await fulfillment(of: [expectation(for: NSPredicate(format: "value == 'Playing'"), evaluatedWith: pause)], timeout: 15)
        // The resolver must use the permanent download when every server endpoint fails.
        let after = try await mediaRequests(baseURL)
        XCTAssertEqual(before, after)
        pause.tap()
        app.terminate()
        try await control("__reset", baseURL: baseURL)
    }

    private func control(_ path: String, baseURL: URL) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }

    private func mediaRequests(_ baseURL: URL) async throws -> Int {
        let (data, _) = try await URLSession.shared.data(from: baseURL.appendingPathComponent("__state"))
        let state = try JSONDecoder().decode(FixtureState.self, from: data)
        return state.mediaRequests
    }
    private struct FixtureState: Decodable { let mediaRequests: Int }
}
#endif
