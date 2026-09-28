//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import MyHeartCountsShared
import XCTest
import XCTestExtensions


final class PromptedActionsTests: MHCTestCase, @unchecked Sendable {
    // Tests that dismissing a prompted action makes it disappear from the home tab
    // (but that it still shows up via the Account Sheet)
    func testPromptedActionDismissal() throws {
        let credentials: SetupTestEnvironmentConfig.Credentials = .random()
        try launchAppAndEnrollIntoStudy(
            testEnvironmentConfig: .init(resetExistingData: true, loginAndEnroll: .enable(credentials)),
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
        app.expandSheet(sheet)
        XCTAssert(sensorKitRow.waitForExistence(timeout: 2))
        
        app.terminate()
        
        try launchAppAndEnrollIntoStudy(
            testEnvironmentConfig: .init(resetExistingData: false, loginAndEnroll: .enable(credentials)),
            skipGoingToHomeTab: true,
            promptedActionsFilter: .only([.sensorKit])
        )
        XCTAssert(digestButton.waitForNonExistence(timeout: 2))
        XCTAssert(app.staticTexts["Complete Your Study Setup"].waitForNonExistence(timeout: 2))
        
        openAccountSheet()
        XCTAssert(digestButton.waitForExistence(timeout: 2))
        digestButton.tap()
        XCTAssert(sheet.waitForExistence(timeout: 2))
        app.expandSheet(sheet)
        XCTAssert(sensorKitRow.waitForExistence(timeout: 2))
    }
    
    
    func testCompleteDemographics() throws {
        try supplyHealthCharacteristics()
        let credentials: SetupTestEnvironmentConfig.Credentials = .random()
        func launchApp(resetExistingData: Bool) throws {
            try self.launchAppAndEnrollIntoStudy(
                testEnvironmentConfig: .init(resetExistingData: resetExistingData, loginAndEnroll: .enable(credentials)),
                skipGoingToHomeTab: launchCounter > 0,
                promptedActionsFilter: .only([.completeDemographics]),
                extraLaunchOptions: [
                    LaunchOptionValue(false, for: .supplyDemographicsWhenCreatingTestAccount)
                ]
            )
            self.goToTab(.home)
        }
        func dismissDemographicsSheet() {
            let navBar = app.navigationBars["Demographics"]
            navBar.buttons.element(matching: "label IN %@", ["Done", "Close"]).tap()
        }
        
        try launchApp(resetExistingData: true)
        
        let digestButton = app.buttons["PromptedActionsDigest"]
        XCTAssert(digestButton.waitForExistence(timeout: 2))
        XCTAssert(app.staticTexts["Complete Your Study Setup"].waitForExistence(timeout: 2))
        XCTAssert(app.staticTexts["1 recommended step to get the most out of the study"].waitForExistence(timeout: 2))
        digestButton.tap()
        XCTAssert(app.navigationBars["Suggested for You"].waitForExistence(timeout: 2))
        let actionsSheet = app.otherElements["PromptedActionsDigestSheet"]
        XCTAssert(actionsSheet.exists)
        let demographicsRow = actionsSheet.otherElements["PromptedActionRow:\(PromptedActionID.completeDemographics.value)"]
        XCTAssert(demographicsRow.exists)
        demographicsRow.buttons["Complete Demographics"].tap()
        
        // since we created a random new account above, the demographics will be completely empty.
        // we first fill out everything except for the referral source.
        // we then kill and relaunch the app, verify that it still prompts us to complete the demographics,
        // then supply the referral source value, close the demographics sheet, and verify that it no longer
        // shows the suggestion.
        // we then kill and relaunch again, and verify that it continues to not show the suggestion.
        let navigator = DemographicsNavigator(testCase: self)
        // needed to make sure that fillInDemographics will work correctly
        navigator.performTestingSupportAction("Reset All")
        navigator.fillInDemographics(skipReferralSource: true)
        sleep(for: .seconds(1.5)) // give it time to sync to server
        dismissDemographicsSheet()
        XCTAssert(demographicsRow.exists)
        app.terminate()
        sleep(for: .seconds(0.5))
        
        try launchApp(resetExistingData: false)
        XCTAssert(digestButton.waitForExistence(timeout: 5))
        digestButton.tap()
        XCTAssert(demographicsRow.waitForExistence(timeout: 2))
        demographicsRow.buttons["Complete Demographics"].tap()
        
        navigator.fillInReferralSourceOption("Friend")
        sleep(for: .seconds(1.5)) // give it time to sync to server
        dismissDemographicsSheet()
        XCTAssert(demographicsRow.waitForNonExistence(timeout: 2))
        
        app.terminate()
        sleep(for: .seconds(0.5))
        
        try launchApp(resetExistingData: false)
        XCTAssert(digestButton.waitForNonExistence(timeout: 5))
    }
}
