// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

//
//  CassetteUITests.swift
//  CassetteUITests
//
//  Created by Mathieu Dubart on 24/04/2026.
//

import XCTest

final class CassetteUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testAppFinishesBooting() throws {
        let app = XCUIApplication()
        app.launch()

        let content = app.descendants(matching: .any)["cassette.content"]
        XCTAssertTrue(
            content.waitForExistence(timeout: 20),
            "The app did not finish booting. Recovery visible: \(app.descendants(matching: .any)["cassette.storage-recovery"].exists)"
        )
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
