//
// This source file is part of the My Heart Counts iOS open-source project
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


final class OtherTests: MHCTestCase, Sendable {
    func testSkippingClinicalRecordsAuthorization() throws {
        guard MHCTestCase.enableHealthRecords else {
            throw XCTSkip("Health Records Testing disabled")
        }
        app.resetAuthorizationStatus(for: .health)
        app.delete(app: "My Heart Counts")
        try launchAppAndEnrollIntoStudy(
            skipGoingToHomeTab: true
        )
        XCTAssert(app.navigationBars["Health Access"].waitForExistence(timeout: 10))
        app.handleHealthKitAuthorization()
        XCTAssert(app.staticTexts["How Sharing Health Records Works"].waitForExistence(timeout: 20))
        app.navigationBars.buttons["Cancel"].tap()
        XCTAssert(app.staticTexts["Welcome to My Heart Counts"].waitForExistence(timeout: 20))
        
        app.terminate()
        try launchAppAndEnrollIntoStudy(
            testEnvironmentConfig: .init(resetExistingData: false, loginAndEnroll: .skip),
            skipGoingToHomeTab: true
        )
        XCTAssert(app.staticTexts["How Sharing Health Records Works"].waitForNonExistence(timeout: 20))
        XCTAssert(app.staticTexts["Welcome to My Heart Counts"].waitForExistence(timeout: 20))
    }
    
    
    /// Tests that passing `testEnvironmentConfig: .init(resetExistingData: false, loginAndEnroll: true)` to
    /// `launchAppAndEnrollIntoStudy` behaves properly (ie, we are logged in and the data from the previous launch remains).
    func testLaunchKeepingData() throws {
        let credentials: SetupTestEnvironmentConfig.Credentials = .random()
        try launchAppAndEnrollIntoStudy(
            testEnvironmentConfig: .init(resetExistingData: true, loginAndEnroll: .enable(credentials))
        )
        XCTAssert(app.staticTexts["Completed"].waitForNonExistence(timeout: 2))
        app.buttons["Read Article: Welcome to My Heart Counts"].tap()
        app.navigationBars.buttons["Close"].tap()
        XCTAssert(app.staticTexts["Completed"].waitForExistence(timeout: 2))
        app.terminate()
        
        try launchAppAndEnrollIntoStudy(
            testEnvironmentConfig: .init(resetExistingData: false, loginAndEnroll: .enable(credentials)),
            skipGoingToHomeTab: true
        )
        XCTAssert(app.staticTexts["Completed"].waitForExistence(timeout: 7))
    }
    
    
    func testUpdateComorbidities() throws {
        let credentials: SetupTestEnvironmentConfig.Credentials = .random()
        try supplyHealthCharacteristics()
        try launchAppAndEnrollIntoStudy(
            testEnvironmentConfig: .init(resetExistingData: true, loginAndEnroll: .skip)
        )
        do {
            let navigator = OnboardingNavigator(testCase: self)
            try navigator.navigateFullOnboardingFlow(
                region: try XCTUnwrap(appLocale.region),
                name: .init(givenName: "Leland", familyName: "Stanford"),
                credentials: credentials,
                signUpForExtraTrial: false,
                consentPresenceCheck: .dontCare
            )
        }
        try launchAppAndEnrollIntoStudy(testEnvironmentConfig: .init(resetExistingData: false, loginAndEnroll: .enable(credentials)))
        openAccountSheet()
        app.swipeUp()
        app.buttons["Update Health Conditions"].tap()
        XCTAssert(app.buttons["Heart Failure, Selected"].waitForExistence(timeout: 4))
        app.buttons["Diabetes"].tap()
        app.navigationBars["Diabetes"].buttons["Done"].tap()
        XCTAssert(app.buttons["Diabetes, Selected"].waitForExistence(timeout: 4))
        app.navigationBars.buttons["Done"].tap()
        sleep(for: .seconds(2)) // give it time to sync
        app.buttons["Update Health Conditions"].tap()
        XCTAssert(app.buttons["Heart Failure, Selected"].waitForExistence(timeout: 4))
        XCTAssert(app.buttons["Diabetes, Selected"].waitForExistence(timeout: 4))
    }
}
