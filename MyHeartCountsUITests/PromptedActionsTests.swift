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


final class PromptedActionsTests: MHCTestCase, @unchecked Sendable {
//    @MainActor
//    func testSensorKitNudgeDismissal() throws {
//        try launchAppAndEnrollIntoStudy()
//        goToTab(.home)
//        XCTAssert(app.staticTexts["Enable SensorKit"].waitForExistence(timeout: 2))
//        app.staticTexts["Enable SensorKit"].press(forDuration: 2)
//        XCTAssert(app.buttons["Stop Suggesting This"].waitForExistence(timeout: 2))
//        app.buttons["Stop Suggesting This"].tap()
//        XCTAssert(app.staticTexts["Enable SensorKit"].waitForNonExistence(timeout: 2))
//        app.terminate()
//        try launchAppAndEnrollIntoStudy(
//            testEnvironmentConfig: .init(resetExistingData: false, loginAndEnroll: false),
//            // no idea why but this sometimes isn't able to find the home tab item's accessibility id (is empty for some reason...)
//            skipGoingToHomeTab: true
//        )
//        XCTAssert(app.staticTexts["Enable SensorKit"].waitForNonExistence(timeout: 5))
//    }
    
    
    @MainActor
    func testSensorKitPrompedAction() throws {
        let extraArgs = [
            "--only-prompted-actions", "edu.stanford.MyHeartCounts.HomeTabAction.EnableSensorKit"
        ]
        try launchAppAndEnrollIntoStudy(
            skipHealthPermissionsHandling: true,
            extraLaunchArgs: extraArgs
        )
        goToTab(.home)
        XCTAssert(app.staticTexts["Complete Your Study Setup"].waitForExistence(timeout: 5))
        XCTAssert(app.staticTexts["1 recommended step to get the most out of the study"].waitForExistence(timeout: 2))
        app.staticTexts["Complete Your Study Setup"].tap()
        XCTAssert(app.navigationBars["Suggested for You"].waitForExistence(timeout: 2))
        let sheet = app.otherElements["PromptedActionsDigestSheet"]
        XCTAssert(sheet.exists)
        let sensorKitRow = sheet.otherElements["PromptedActionRow:edu.stanford.MyHeartCounts.HomeTabAction.EnableSensorKit"]
        XCTAssert(sensorKitRow.exists)
        sensorKitRow.buttons["Don't suggest “Enable SensorKit” again"].tap()
        sleep(for: .seconds(1))
        app.buttons["Stop Suggesting This"].tap()
        XCTAssert(sensorKitRow.waitForNonExistence(timeout: 2))
        XCTAssert(sheet.waitForNonExistence(timeout: 2))
        
        app.terminate()
        sleep(for: .seconds(2))
        
        try launchAppAndEnrollIntoStudy(
            testEnvironmentConfig: .init(resetExistingData: false, loginAndEnroll: false),
            skipHealthPermissionsHandling: true,
            skipGoingToHomeTab: true,
            extraLaunchArgs: extraArgs
        )
        goToTab(.home)
        XCTAssert(app.staticTexts["Complete Your Study Setup"].waitForNonExistence(timeout: 5))
    }
}
