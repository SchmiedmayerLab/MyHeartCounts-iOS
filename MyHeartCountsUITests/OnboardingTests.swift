//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import MyHeartCountsShared
import XCTest
import XCTestExtensions


final class OnboardingTests: MHCTestCase, @unchecked Sendable {
    override func tearDown() async throws {
        app.terminate()
        // Reset HealthKit authorization after every test in this class.
        //
        // `testOnboardingDemographicsWithoutHealthKitWriteAccess` deliberately grants only a partial set of
        // permissions; leaving that behind would make whichever test runs next (the plan uses random ordering)
        // inherit a read-only, single-sample-type grant. Doing this in `tearDown` rather than at the end of the
        // test body means it also happens when the test fails partway through.
        app.resetAuthorizationStatus(for: .health)
        try await super.tearDown()
    }
    
    func testOnboardingFlow() throws {
        try supplyHealthCharacteristics()
        try launchAppAndEnrollIntoStudy(
            locale: .enUS,
            testEnvironmentConfig: .init(resetExistingData: true, loginAndEnroll: .skip),
            skipGoingToHomeTab: true
        )
        let navigator = OnboardingNavigator(testCase: self)
        try navigator.navigateFullOnboardingFlow(
            region: .unitedStates,
            name: .init(givenName: "Leland", familyName: "Stanford"),
            credentials: .random(),
            signUpForExtraTrial: true,
            consentPresenceCheck: .dontCare
        )
        XCTAssert(app.staticTexts["Welcome to My Heart Counts"].waitForExistence(timeout: 5))
    }
    
    
    func testRegionEligibilityComingSoon() throws {
        try launchAppAndEnrollIntoStudy(
            locale: .enUS,
            testEnvironmentConfig: .init(resetExistingData: true, loginAndEnroll: .skip),
            skipGoingToHomeTab: true
        )
        let navigator = OnboardingNavigator(testCase: self)
        navigator.navigateWelcome()
        try navigator.navigateEligibility(region: .unitedKingdom)
        XCTAssert(app.staticTexts["Coming Soon"].waitForExistence(timeout: 5))
    }
    
    
    func testRegionEligibilityNotSupported() throws {
        try launchAppAndEnrollIntoStudy(
            locale: .enUS,
            testEnvironmentConfig: .init(resetExistingData: true, loginAndEnroll: .skip),
            skipGoingToHomeTab: true
        )
        let navigator = OnboardingNavigator(testCase: self)
        navigator.navigateWelcome()
        try navigator.navigateEligibility(region: .germany)
        XCTAssert(app.staticTexts["Region Not Yet Supported"].waitForExistence(timeout: 5))
    }
    
    
    func testOnboardingDemographicsWithoutHealthKitWriteAccess() throws { // swiftlint:disable:this function_body_length
        app.resetAuthorizationStatus(for: .health)
        try launchAppAndEnrollIntoStudy(
            locale: .enUS,
            testEnvironmentConfig: .init(resetExistingData: true, loginAndEnroll: .skip),
            skipGoingToHomeTab: true
        )
        let navigator = OnboardingNavigator(testCase: self)
        try navigator.navigateOnboardingFlowUntilHealthKit(
            region: .unitedStates,
            name: PersonNameComponents(givenName: "Leland", familyName: "Stanford"),
            credentials: .random(),
            signUpForExtraTrial: false,
            consentPresenceCheck: .dontCare
        )
        XCTAssert(app.staticTexts["HealthKit Access"].waitForExistence(timeout: 7))
        app.buttons["Continue"].tap()
        
        let healthAccessPrompt = app.staticTexts.matching(
            "label LIKE %@ OR label LIKE %@",
            "* would like to access and update your Health data*", // before iOS 27
            "Allow * to access your Health data*" // iOS 27
        )
        XCTAssert(healthAccessPrompt.element.waitForExistence(timeout: 7))
        do {
            let toggle = app.switches["Active Energy"]
            XCTAssert(toggle.waitForExistence(timeout: 2))
            // Off-screen rows can't be tapped; iOS 27 lists Active Energy further down than iOS 26.
            for _ in 0..<10 where !toggle.isHittable {
                app.tables.firstMatch.swipeUp()
            }
            sleep(for: .seconds(0.5))
            XCTAssertEqual(try XCTUnwrap(toggle.value as? String), "0")
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            sleep(for: .seconds(1))
            XCTAssertEqual(try XCTUnwrap(toggle.value as? String), "1")
        }
        sleep(for: .seconds(2))

        // "Allow" is a bar button before iOS 27; from iOS 27 it's at the end of the list and has to be scrolled to,
        // and a second page then asks how much history to share.
        let allowButton = app.buttons.matching("identifier == %@ OR label == %@", "UIA.Health.Allow.Button", "Allow").firstMatch
        for _ in 0..<12 where !(allowButton.exists && allowButton.isHittable) {
            app.swipeUp()
        }
        allowButton.tap()
        let allRecordedData = app.descendants(matching: .any).matching("label BEGINSWITH %@", "All Recorded Data").firstMatch
        if allRecordedData.waitForExistence(timeout: 5) {
            allRecordedData.tap()
            XCTAssert(app.buttons["Allow"].wait(for: \.isHittable, toEqual: true, timeout: 10))
            app.buttons["Allow"].tap()
        }
        navigator.navigateWorkoutPreferences()
        navigator.navigateHealthRecordsIfNecessary()
        navigator.navigateNotificationsIfNecessary()
        XCTAssert(app.navigationBars["Demographics"].waitForExistence(timeout: 2))
        
        do { // enter height
            app.collectionViews["DemographicsForm"]
                .buttons
                .containing(.staticText, identifier: "Height")
                .element
                .tap()
            app.staticTexts["MHC:HeightRow"].tap()
            app.navigationBars["Enter Height"].buttons["Save"].tap()
            XCTAssert(app.buttons["Height, 5‘ 4“"].waitForExistence(timeout: 1))
        }
        do { // enter weight
            app.collectionViews["DemographicsForm"]
                .buttons
                .containing(.staticText, identifier: "Weight")
                .element
                .tap()
            app.textFields["QuantityDataEntry:Weight"].typeText("147")
            app.navigationBars["Enter Weight"].buttons["Save"].tap()
            XCTAssert(app.buttons["Weight, 147 lb"].waitForExistence(timeout: 1))
        }
        
        // thesis: if we get to this point in the onboarding, we will make it to the end
    }
}
