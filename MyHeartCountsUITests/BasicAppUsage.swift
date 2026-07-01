//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import HealthKit
import MyHeartCountsShared
import XCTest
import XCTestExtensions
import XCTHealthKit


final class BasicAppUsage: MHCTestCase, Sendable {
    func testRootLevelNavigation() throws {
        try launchAppAndEnrollIntoStudy()
        goToTab(.upcoming)
        XCTAssert(app.navigationBars.staticTexts["Tasks"].waitForExistence(timeout: 2))
        goToTab(.heartHealth)
        XCTAssert(app.navigationBars.staticTexts["MHC Heart Health"].waitForExistence(timeout: 2))
    }
    
    
    func testInformativeContent() throws {
        try launchAppAndEnrollIntoStudy()
        let articleTaskCompletedLabel = app.staticTexts["Welcome to My Heart Counts, Completed"]
        XCTAssert(articleTaskCompletedLabel.waitForNonExistence(timeout: 2))
        do {
            let button = app.buttons["Read Article: Welcome to My Heart Counts"]
            XCTAssert(button.waitForExistence(timeout: 2))
            button.tap()
        }
        XCTAssert(app.images["stanford"].waitForExistence(timeout: 2))
        do {
            let pred = NSPredicate(format: "label BEGINSWITH 'We’re thrilled to have you on board.'")
            XCTAssert(app.staticTexts.element(matching: pred).waitForExistence(timeout: 1))
        }
        app.navigationBars.buttons["Close"].tap()
        XCTAssert(articleTaskCompletedLabel.waitForExistence(timeout: 2))
    }
    
    
    func testFeedback() throws {
        try launchAppAndEnrollIntoStudy()
        openAccountSheet()
        app.swipeUp()
        app.staticTexts["Send Feedback"].tap()
        XCTAssert(app.navigationBars["Feedback"].waitForExistence(timeout: 2))
        let sendButton = app.navigationBars["Feedback"].buttons["Send"]
        XCTAssert(sendButton.exists)
        XCTAssertFalse(sendButton.isEnabled)
        app.textViews["MHC.FeedbackTextField"].typeText("Heyyyy ;)")
        XCTAssert(sendButton.isEnabled)
        sendButton.tap()
        XCTAssert(app.navigationBars["Feedback"].waitForNonExistence(timeout: 2))
    }
    
    
    func testLogout() throws {
        try launchAppAndEnrollIntoStudy()
        openAccountSheet()
        app.swipeUp()
        app.buttons["Logout"].tap()
        app.alerts["Are you sure you want to logout?"].buttons["Logout"].tap()
        XCTAssert(app.staticTexts["Welcome to the My Heart Counts\nCardiovascular Health Study"].waitForExistence(timeout: 5))
    }
    
    
    func testWithdrawal() throws {
        throw XCTSkip("needs https://github.com/SchmiedmayerLab/MyHeartCounts-Firebase/pull/111")
        try launchAppAndEnrollIntoStudy(locale: .enUS)
        openAccountSheet()
        app.swipeUp()
        app.navigationBars.buttons["Edit"].tap()
        app.buttons["Withdraw from Study"].tap()
        app.alerts["Withdraw from Study"].buttons["Withdraw"].tap()
        let navigator = OnboardingNavigator(testCase: self)
        navigator.navigateWelcome(timeout: 10)
        try navigator.navigateEligibility(region: .unitedStates)
        try navigator.navigateSignup(
            name: .init(givenName: "Leland", familyName: "Stanford"),
            email: TestingConstants.loginCredentials.email,
            password: TestingConstants.loginCredentials.password
        )
        XCTAssert(app.staticTexts["Reactivate Account"].waitForExistence(timeout: 10))
        app.buttons["Reactivate Account"].tap()
        navigator.navigateOnboardingDisclaimers()
    }
}
