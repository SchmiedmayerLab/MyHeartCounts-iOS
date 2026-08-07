//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import MyHeartCountsShared
import XCTest
import XCTestExtensions


final class OnboardingTests: MHCTestCase, Sendable {
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
        
        XCTAssert(
            app.staticTexts.matching("label LIKE %@", "* would like to access and update your Health data*").element.waitForExistence(timeout: 7)
        )
        app.tables.firstMatch.swipeUp()
        do {
            let toggle = app.switches["Active Energy"]
            XCTAssert(toggle.waitForExistence(timeout: 2))
            sleep(for: .seconds(0.5))
            XCTAssertEqual(try XCTUnwrap(toggle.value as? String), "0")
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            sleep(for: .seconds(1))
            XCTAssertEqual(try XCTUnwrap(toggle.value as? String), "1")
        }
        sleep(for: .seconds(2))
        
        app.buttons["UIA.Health.Allow.Button"].tap()
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
