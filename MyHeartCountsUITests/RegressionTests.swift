//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import XCTest


final class RegressionTests: MHCTestCase, @unchecked Sendable {
    @MainActor
    func testFB22483867() throws {
        try launchAppAndEnrollIntoStudy()
        openAccountSheet()
        XCTAssert(app.staticTexts["Sign-In & Security"].waitForExistence(timeout: 5))
        app.staticTexts["Sign-In & Security"].tap()
        XCTAssert(app.buttons["Change Password"].waitForExistence(timeout: 2))
        XCUIDevice.shared.press(.home)
        sleep(for: .seconds(3))
        app.activate()
        XCTAssert(app.buttons["Change Password"].waitForExistence(timeout: 2))
    }
}
