//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import MyHeartCountsShared
import XCTest
import XCTestExtensions


final class PromptedActionsTests: MHCTestCase, Sendable {
    // Tests that dismissing a prompted action makes it disappear from the home tab
    // (but that it still shows up via the Account Sheet)
    func testPromptedActionDismissal() throws {
        try launchAppAndEnrollIntoStudy(
            promptedActionsFilter: .only([.sensorKit])
        )
        goToTab(.home)
        let digestButton = app.buttons["PromptedActionsDigest"]
        XCTAssert(digestButton.waitForExistence(timeout: 2))
        XCTAssert(app.staticTexts["Complete Your Study Setup"].waitForExistence(timeout: 2))
        XCTAssert(app.staticTexts["1 recommended step to get the most out of the study"].waitForExistence(timeout: 2))
        digestButton.tap()
        XCTAssert(app.navigationBars["Suggested for You"].waitForExistence(timeout: 2))
        let sheet = app.otherElements["PromptedActionsDigestSheet"]
        XCTAssert(sheet.exists)
        let sensorKitRow = sheet.otherElements["PromptedActionRow:\(PromptedActionID.sensorKit.value)"]
        XCTAssert(sensorKitRow.exists)
        sensorKitRow.buttons["Don't suggest “Enable SensorKit” again"].tap()
        sleep(for: .seconds(1))
        app.buttons["Stop Suggesting This"].tap()
        XCTAssert(sensorKitRow.waitForNonExistence(timeout: 2))
        XCTAssert(sheet.waitForNonExistence(timeout: 2))
        XCTAssert(digestButton.waitForNonExistence(timeout: 2))
        
        openAccountSheet()
        XCTAssert(digestButton.waitForExistence(timeout: 2))
        digestButton.tap()
        XCTAssert(sheet.waitForExistence(timeout: 2))
        sheet.navigationBars.element.swipeUp()
        XCTAssert(sensorKitRow.waitForExistence(timeout: 2))
        
        app.terminate()
        sleep(for: .seconds(2))
        
        try launchAppAndEnrollIntoStudy(
            testEnvironmentConfig: .init(resetExistingData: false, loginAndEnroll: true),
            skipHealthPermissionsHandling: true,
            skipGoingToHomeTab: true,
            promptedActionsFilter: .only([.sensorKit])
        )
        XCTAssert(digestButton.waitForNonExistence(timeout: 2))
        XCTAssert(app.staticTexts["Complete Your Study Setup"].waitForNonExistence(timeout: 2))
        
        openAccountSheet()
        XCTAssert(digestButton.waitForExistence(timeout: 2))
        digestButton.tap()
        XCTAssert(sheet.waitForExistence(timeout: 2))
        sheet.navigationBars.element.swipeUp()
        XCTAssert(sensorKitRow.waitForExistence(timeout: 2))
    }
}
