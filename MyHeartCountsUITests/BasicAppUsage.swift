//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import HealthKit
import MHCStudyDefinition
import MyHeartCountsShared
import XCTest
import XCTestExtensions
import XCTHealthKit


final class BasicAppUsage: MHCTestCase, @unchecked Sendable {
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
    
    
    /// Taps the account sheet's footer, which releases a Kitten Mode critter.
    func testKittenMode() throws {
        try launchAppAndEnrollIntoStudy()
        openAccountSheet()
        let footer = app.staticTexts.element(matching: NSPredicate(format: "label BEGINSWITH 'Made with'"))
        for _ in 0..<3 where !footer.isHittable {
            app.swipeUp()
        }
        XCTAssert(footer.waitForExistence(timeout: 2))
        footer.tap()
    }


    func testLogout() throws {
        try launchAppAndEnrollIntoStudy()
        openAccountSheet()
        app.swipeUp()
        app.buttons["Log Out"].tap()
        app.alerts["Log Out"].buttons["Log Out"].tap()
        XCTAssert(app.staticTexts["Welcome to the My Heart Counts\nCardiovascular Health Study"].waitForExistence(timeout: 20))
    }
    
    
    func testWithdrawal() throws {
        throw XCTSkip("needs https://github.com/SchmiedmayerLab/MyHeartCounts-Firebase/pull/111")
        let credentials: SetupTestEnvironmentConfig.Credentials = .random()
        try launchAppAndEnrollIntoStudy(
            locale: .enUS,
            testEnvironmentConfig: .init(resetExistingData: true, loginAndEnroll: .enable(credentials))
        )
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
            credentials: credentials
        )
        XCTAssert(app.staticTexts["Reactivate Account"].waitForExistence(timeout: 10))
        app.buttons["Reactivate Account"].tap()
        navigator.navigateOnboardingDisclaimers()
    }


    /// Participants who withdrew sign the consent again when they re-enroll, even though they already signed its current version.
    /// The account is reactivated only once they have signed it, so an interrupted re-enrollment asks for the consent again.
    /// (Runs as an Imperial participant, whose withdrawal includes signing the withdrawal form.)
    func testReenrollmentAfterWithdrawalRequiresConsent() throws {
        let credentials: SetupTestEnvironmentConfig.Credentials = .random()
        try launchAppAndEnrollIntoStudy(
            studyVariant: .imperial,
            testEnvironmentConfig: .init(resetExistingData: true, loginAndEnroll: .enable(credentials))
        )
        openAccountSheet()
        app.swipeUp()
        // the Imperial account sheet lists "Withdraw from Study" without going through "Edit"
        app.buttons["Withdraw from Study"].tap()
        app.alerts["Withdraw from Study"].buttons["Withdraw"].tap()
        signWithdrawalForm()

        let navigator = OnboardingNavigator(testCase: self)
        let name = PersonNameComponents(givenName: "Leland", familyName: "Stanford")
        let consentFlowIndicator = app.staticTexts["Study Overview & Participation"]
        navigator.navigateWelcome(timeout: 10)
        try navigator.navigateEligibility(region: nil)
        try navigator.navigateSignup(name: name, credentials: credentials)
        XCTAssert(app.staticTexts["Reactivate Account"].waitForExistence(timeout: 10))
        app.buttons["Reactivate Account"].tap()
        XCTAssert(consentFlowIndicator.waitForExistence(timeout: 10))

        // leaving the consent flow without signing keeps the account withdrawn
        app.terminate()
        try launchAppAndEnrollIntoStudy(
            studyVariant: .imperial,
            testEnvironmentConfig: .init(resetExistingData: false, loginAndEnroll: .skip),
            skipGoingToHomeTab: true
        )
        navigator.navigateWelcome(timeout: 10)
        try navigator.navigateEligibility(region: nil)
        try navigator.navigateSignup(name: name, credentials: credentials)
        XCTAssert(app.staticTexts["Reactivate Account"].waitForExistence(timeout: 10))
        app.buttons["Reactivate Account"].tap()
        XCTAssert(consentFlowIndicator.waitForExistence(timeout: 10))
    }

    private func signWithdrawalForm() {
        let toggle = app.scrollViews.switches["ConsentForm:withdraw-from-study"].switches.firstMatch
        XCTAssert(toggle.waitForExistence(timeout: 10))
        while !toggle.isHittable {
            app.swipeUp()
        }
        if toggle.value as? String == "0" {
            toggle.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5)).tap()
        }
        let signature = app.scrollViews["ConsentForm:sig"]
        while !signature.isHittable {
            app.swipeUp()
        }
        signature.swipeRight()
        sleep(for: .seconds(0.25))
        // the form's button, rather than the account sheet's button of the same name underneath the form
        let withdrawButton = app.scrollViews.buttons["Withdraw from Study"].firstMatch
        while !withdrawButton.isHittable {
            app.swipeUp()
        }
        XCTAssert(withdrawButton.isEnabled)
        withdrawButton.tap()
    }
}
