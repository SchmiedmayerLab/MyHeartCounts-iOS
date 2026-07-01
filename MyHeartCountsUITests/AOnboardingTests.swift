//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

// swiftlint:disable file_types_order

import HealthKit
import MyHeartCountsShared
import XCTest
import XCTestExtensions
import XCTHealthKit
import XCTSpeziAccount
import XCTSpeziNotifications


// named like this bc tests are run based on the alpabetic ordering of the test classes, and we want this one to run first.
final class AOnboardingTests: MHCTestCase, Sendable {
    func testAOnboardingFlow() throws {
        try launchHealthAppAndEnterCharacteristics(.init(
            bloodType: .aPositive,
            dateOfBirth: .init(year: 1998, month: 6, day: 2),
            biologicalSex: .male,
            skinType: .II,
            wheelchairUse: .no
        ))
        try launchAppAndEnrollIntoStudy(
            locale: .enUS,
            testEnvironmentConfig: .init(resetExistingData: true, loginAndEnroll: false),
            skipHealthPermissionsHandling: true,
            skipGoingToHomeTab: true,
        )
        let navigator = OnboardingNavigator(testCase: self)
        try navigator.navigateFullOnboardingFlow(
            region: .unitedStates,
            name: .init(givenName: "Leland", familyName: "Stanford"),
            email: TestingConstants.loginCredentials.email,
            password: TestingConstants.loginCredentials.password,
            signUpForExtraTrial: true
        )
    }
    
    
    func testReviewConsentForms() throws {
        try launchAppAndEnrollIntoStudy(testEnvironmentConfig: .init(resetExistingData: true, loginAndEnroll: true))
        // check that the consent we just signed is showing up in the Account Sheet
        openAccountSheet()
        XCTAssert(app.staticTexts["Review Consent Forms"].waitForExistence(timeout: 2))
        app.staticTexts["Review Consent Forms"].tap()
        XCTAssert(app.collectionViews.cells.staticTexts["My Heart Counts Consent Form"].waitForExistence(timeout: 2))
        app.collectionViews.cells.buttons.element(matching: "label CONTAINS %@", "My Heart Counts Consent Form").firstMatch.tap()
        let consentPdf = app.otherElements["QLPreviewControllerView"].textViews.element
        XCTAssert(consentPdf.waitForExistence(timeout: 5))
        XCTAssert(consentPdf.staticTexts["My Heart Counts Consent Form"].waitForExistence(timeout: 2))
        XCTAssert(consentPdf.staticTexts["# STANFORD UNIVERSITY\n## CONSENT TO BE PART OF A RESEARCH STUDY"].waitForExistence(timeout: 2))
        XCTAssert(
            consentPdf.staticTexts.element(
                matching: "label BEGINSWITH %@", #"You are invited to participate in a research study, "My Heart Counts,""#
            )
            .waitForExistence(timeout: 2)
        )
    }
    
    
    func testRegionEligibilityComingSoon() throws {
        try launchAppAndEnrollIntoStudy(
            locale: .enUS,
            testEnvironmentConfig: .init(resetExistingData: true, loginAndEnroll: false),
            skipHealthPermissionsHandling: true,
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
            testEnvironmentConfig: .init(resetExistingData: true, loginAndEnroll: false),
            skipHealthPermissionsHandling: true,
            skipGoingToHomeTab: true
        )
        let navigator = OnboardingNavigator(testCase: self)
        navigator.navigateWelcome()
        try navigator.navigateEligibility(region: .germany)
        XCTAssert(app.staticTexts["Region Not Yet Supported"].waitForExistence(timeout: 5))
    }
}


@MainActor
struct OnboardingNavigator { // swiftlint:disable:this type_body_length
    let testCase: MHCTestCase
    
    private var app: XCUIApplication {
        testCase.app
    }
    
    
    func navigateFullOnboardingFlow(
        region: Locale.Region,
        name: PersonNameComponents,
        email: String,
        password: String,
        signUpForExtraTrial: Bool
    ) throws {
        navigateWelcome()
        try navigateEligibility(region: region)
        try navigateSignup(name: name, email: email, password: password)
        navigateOnboardingDisclaimers()
        navigateConsentComprehension()
        navigateConsent(expectedName: name, signUpForExtraTrial: signUpForExtraTrial)
        navigateHealthKitAccess()
        if app.staticTexts["Health Records"].waitForExistence(timeout: 2) { // only included if Health Records are actually available
            navigateHealthRecords()
        }
        navigateWorkoutPreferences()
        if app.staticTexts["Notifications"].waitForExistence(timeout: 2) { // this step is skipped if sufficient permissions have already been granted
            navigateNotifications()
        }
        navigateDemographics()
        navigateFinalOnboardingStep(signUpForExtraTrial: signUpForExtraTrial)
    }
    
    
    func navigateWelcome(timeout: TimeInterval = 2) {
        XCTAssert(
            app.staticTexts.element(
                matching: "label MATCHES %@", "Welcome to the My Heart Counts(\\n| )Cardiovascular Health Study"
            )
            .waitForExistence(timeout: timeout)
        )
        app.buttons["Continue"].tap()
    }
    
    
    func navigateEligibility(region: Locale.Region) throws {
        let continueButton = app.collectionViews.firstMatch.buttons["Continue"]
        let ofAgeToggle = app.switches["Are you 18 years old or older?"].descendants(matching: .switch).firstMatch
        XCTAssert(ofAgeToggle.waitForExistence(timeout: 2))
        XCTAssertEqual(try XCTUnwrap(ofAgeToggle.value as? String), "0")
        ofAgeToggle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        sleep(for: .seconds(0.25))
        XCTAssertEqual(try XCTUnwrap(ofAgeToggle.value as? String), "1")
        app.buttons["What country do you currently live in?"].tap()
        sleep(for: .seconds(0.55))
        do {
            app.searchFields["Search"].firstMatch.tap()
            app.searchFields["Search"].firstMatch.typeText(try XCTUnwrap(region.name()))
            let countryButton = app.buttons[try XCTUnwrap(region.name(includeEmoji: true))]
            XCTAssert(countryButton.waitForExistence(timeout: 1))
            countryButton.tap()
            sleep(for: .seconds(0.25))
            app.swipeUp()
            XCTAssertFalse(continueButton.isEnabled)
        }
        app.otherElements["Screening Section, Language"].buttons["Yes"].tryToTapReallySoftlyMaybeThisWillMakeItWork()
        XCTAssertFalse(continueButton.isEnabled)
        app.otherElements["Screening Section, Apple ID Sharing"].buttons["No"].tryToTapReallySoftlyMaybeThisWillMakeItWork()
        XCTAssertTrue(continueButton.isEnabled)
        continueButton.tap()
    }
    
    
    func navigateSignup(name: PersonNameComponents, email: String, password: String) throws {
        XCTAssert(app.staticTexts["Your Account"].waitForExistence(timeout: 10))
        let isLoggedIn = app.staticTexts
            .matching("label BEGINSWITH %@", "You are already logged in")
            .element
            .waitForExistence(timeout: 2)
        if !isLoggedIn {
            defer {
                app.dismissSavePasswordAlert(timeout: 10)
            }
            try app.login(email: email, password: password)
            let alert = app.alerts["Invalid Credentials"]
            if alert.waitForNonExistence(timeout: 3) {
                // no "invalid credentials" alert showed up, meaning that we did not try to log in to a non-existant user.
                return
            }
            // we need to sign up instead of logging in
            alert.buttons["OK"].tap()
            
            app.buttons["Signup"].tap()
            sleep(for: .seconds(0.5))
            XCTAssertFalse(app.collectionViews.firstMatch.buttons["Signup"].isEnabled) // this ia a different button from the one we just tapped.
            try app.fillSignupForm(email: email, password: password, name: name)
            XCTAssert(app.collectionViews.firstMatch.buttons["Signup"].isEnabled)
            app.collectionViews.firstMatch.buttons["Signup"].tap()
        } else {
            if let firstName = name.givenName, let lastName = name.familyName {
                XCTAssert(app.staticTexts["\(firstName) \(lastName)"].waitForExistence(timeout: 2))
            }
            XCTAssert(app.staticTexts[email].waitForExistence(timeout: 2))
            app.buttons["Next"].tap()
        }
    }
    
    
    func navigateOnboardingDisclaimers(initialTimeout: TimeInterval = 10) {
        struct StepInfo {
            let title: String
            let bodyPrefix: String
            let learnMorePrefix: String
        }
        
        let steps = [
            StepInfo(
                title: "Study Overview & Participation",
                bodyPrefix: "You’re invited to join a Stanford research study",
                learnMorePrefix: "This research study is conducted by Stanford University School of Medicine researchers"
            ),
            StepInfo(
                title: "Trial Component",
                bodyPrefix: "You have the option to enroll",
                learnMorePrefix: "The optional trial uses a"
            ),
            StepInfo(
                title: "Data Collection & Privacy",
                bodyPrefix: "We will collect data from the Health app",
                learnMorePrefix: "The study collects data through your phone's sensors"
            ),
            StepInfo(
                title: "Risks, Benefits & Your Rights",
                bodyPrefix: "Participation is completely voluntary",
                learnMorePrefix: "Physical risks are minimal"
            )
        ]
        
        for (idx, step) in steps.enumerated() {
            XCTAssert(app.staticTexts[step.title].waitForExistence(timeout: idx == 0 ? initialTimeout : 2))
            XCTAssert(
                app.staticTexts.matching("label BEGINSWITH %@", step.bodyPrefix).firstMatch.waitForExistence(timeout: 2),
                "Unable to find staticText with prefix '\(step.bodyPrefix)'"
            )
            app.buttons["Learn More"].tap()
            XCTAssert(
                app.staticTexts.matching("label BEGINSWITH %@", step.learnMorePrefix).firstMatch.waitForExistence(timeout: 2),
                "Unable to find staticText with prefix '\(step.learnMorePrefix)'"
            )
            app.navigationBars.buttons["Close"].tap()
            app.buttons["Continue"].tap()
        }
    }
    
    
    private func navigateConsent(expectedName: PersonNameComponents?, signUpForExtraTrial: Bool) { // swiftlint:disable:this function_body_length
        sleep(for: .seconds(2))
        XCTAssert(app.scrollViews.staticTexts["STANFORD UNIVERSITY"].waitForExistence(timeout: 2))
        XCTAssert(app.scrollViews.staticTexts["CONSENT TO BE PART OF A RESEARCH STUDY"].waitForExistence(timeout: 2))
        func scrollToSwitchAndEnable(
            identifier: String,
            isOn: Bool,
            expectedDirection: XCUIElement.Direction,
            file: StaticString = #filePath,
            line: UInt = #line
        ) {
            while !app.scrollViews.switches[identifier].isHittable {
                app.swipe(expectedDirection.opposite, velocity: .fast)
            }
            let toggle = app.scrollViews.switches[identifier].switches.firstMatch
            switch (toggle.value as? String, isOn) {
            case ("0", true), ("1", false):
                toggle.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5)).tap()
            case ("0", false), ("1", true):
                break
            default:
                XCTFail("Unable to decode switch value", file: file, line: line)
            }
        }
        func scrollToDropdownAndSelect(
            identifier: String,
            option: String,
            expectedDirection: XCUIElement.Direction,
            file: StaticString = #filePath,
            line: UInt = #line
        ) {
            while !app.scrollViews.buttons[identifier].isHittable {
                app.swipe(expectedDirection.opposite, velocity: .fast)
            }
            app.scrollViews.buttons[identifier].tap()
            app.collectionViews.buttons[option].tap()
        }
//        scrollToSwitchAndEnable(identifier: "ConsentForm:future-studies", isOn: true, expectedDirection: .down)
        scrollToDropdownAndSelect(
            identifier: "ConsentForm:short-term-physical-activity-trial",
            option: signUpForExtraTrial ? "Yes" : "No",
            expectedDirection: .down
        )
        app.swipeUp()
        XCTAssertFalse(app.buttons["I Consent"].isEnabled)
        app.scrollViews["ConsentForm:sig"].swipeRight()
        if let firstName = expectedName?.givenName, let lastName = expectedName?.familyName {
            XCTAssert(app.staticTexts["Name: \(firstName) \(lastName)"].waitForExistence(timeout: 1))
        }
        sleep(for: .seconds(0.25))
        XCTAssert(app.buttons["I Consent"].isEnabled)
        app.buttons["I Consent"].tap()
        sleep(for: .seconds(0.5))
    }
    
    
    private func navigateConsentComprehension() {
        let continueButton = app.collectionViews.firstMatch.buttons["Continue"]
        if continueButton.exists {
            XCTAssertFalse(continueButton.isEnabled)
        }
        XCTAssert(app.staticTexts["Consent Survey"].waitForExistence(timeout: 2))
        app.otherElements["Screening Section, 0"].buttons["True"].tryToTapReallySoftlyMaybeThisWillMakeItWork()
        if continueButton.exists {
            XCTAssertFalse(continueButton.isEnabled)
        }
        app.otherElements["Screening Section, 1"].buttons["True"].tryToTapReallySoftlyMaybeThisWillMakeItWork()
        if continueButton.exists {
            XCTAssertFalse(continueButton.isEnabled)
        }
        app.swipeUp()
        app.otherElements["Screening Section, 2"].buttons["True"].tryToTapReallySoftlyMaybeThisWillMakeItWork()
        XCTAssertTrue(continueButton.isEnabled)
        continueButton.tap()
    }
    
    
    private func navigateHealthKitAccess() {
        XCTAssert(app.staticTexts["HealthKit Access"].waitForExistence(timeout: 10))
        // ^it might take a bit for the previous step (consent upload) to finish)
        app.buttons["Continue"].tap()
        app.handleHealthKitAuthorization()
    }
    
    
    private func navigateHealthRecords() {
        let title = app.staticTexts["Health Records"]
        XCTAssert(title.waitForExistence(timeout: 2))
        app.buttons["Review Permissions"].tap()
        testCase.handleHealthRecordsAuthorization()
        XCTAssert(title.waitForNonExistence(timeout: 10)) // give it some time to complete the auth
    }
    
    
    private func navigateNotifications() {
        XCTAssert(app.staticTexts["Notifications"].waitForExistence(timeout: 2))
        app.buttons["Allow Notifications"].tap()
        app.confirmNotificationAuthorization()
    }
    
    
    private func navigateWorkoutPreferences() {
        XCTAssert(app.staticTexts["Workout Preference"].waitForExistence(timeout: 2))
        XCTAssert(app.staticTexts["Cycling"].waitForExistence(timeout: 2))
        app.staticTexts["Cycling"].tap()
        app.swipeUp()
        app.buttons["Continue"].tap()
    }
    
    
    private func navigateDemographics() { // swiftlint:disable:this function_body_length
        XCTAssert(app.staticTexts["Demographics"].waitForExistence(timeout: 2))
        
        XCTAssert(app.navigationBars["Demographics"].waitForExistence(timeout: 1))
        XCTAssert(app.navigationBars.staticTexts["Demographics"].waitForExistence(timeout: 1))
        do {
            let button = app.navigationBars["Demographics"].buttons["Testing Support"]
            XCTAssert(button.waitForExistence(timeout: 1))
            button.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5)).tap()
            let optionTitle = "Add Height & Weight Samples"
            XCTAssert(app.buttons[optionTitle].waitForExistence(timeout: 1))
            app.buttons[optionTitle].tap()
            app.handleHealthKitAuthorization()
        }
        app.buttons["Read from Health App"].tap()
        XCTAssert(
            app.datePickers.matching("label = %@ AND value = %@", "Date of Birth", "1998-06-02").element.waitForExistence(timeout: 2)
        )
        switch testCase.appLocale.measurementSystem {
        case .us:
            XCTAssert(app.buttons["Height, 6‘ 1“"].waitForExistence(timeout: 2))
            XCTAssert(app.buttons["Weight, 154.32 lb"].waitForExistence(timeout: 2))
        default:
            XCTAssert(app.buttons["Height, 186 cm"].waitForExistence(timeout: 2))
            XCTAssert(app.buttons["Weight, 70 kg"].waitForExistence(timeout: 2))
        }
        
        app.swipeUp()
        
        app.staticTexts["Race / Ethnicity"].tap()
        app.buttons["Prefer not to state"].tap()
        app.buttons["White"].tap()
        app.buttons["Alaska Native"].tap()
        app.navigationBars.buttons["BackButton"].tap()
        XCTAssert(app.buttons["Race / Ethnicity, White, Alaska Native"].waitForExistence(timeout: 1))
        
        app.staticTexts["Are you Hispanic/Latino?"].tap()
        app.buttons["No"].tap()
        app.navigationBars.buttons["BackButton"].tap()
        XCTAssert(app.buttons["Are you Hispanic/Latino?, No"].waitForExistence(timeout: 1))
        
        app.staticTexts["Comorbidities"].tap()
        app.buttons["Heart Failure"].tap()
        app.navigationBars.buttons["Done"].tap()
        app.navigationBars.buttons["BackButton"].tap()
        XCTAssert(app.buttons["Comorbidities, 1 selected"].waitForExistence(timeout: 1))
        
        app.staticTexts["US State / Territory"].tap()
        app.buttons["District of Columbia, DC"].tap()
        app.navigationBars.buttons["BackButton"].tap()
        XCTAssert(app.buttons["US State / Territory, DC"].waitForExistence(timeout: 1))
        
        if app.staticTexts["Education Level"].waitForExistence(timeout: 2) {
            app.staticTexts["Education Level"].tap()
            app.buttons["Master's Degree"].tap()
            app.navigationBars.buttons["BackButton"].tap()
            XCTAssert(app.buttons["Education Level, Master's Degree"].waitForExistence(timeout: 1))
        }
        
        app.staticTexts["Total Household Income"].tap()
        app.buttons["Prefer not to state"].tap()
        app.navigationBars.buttons["BackButton"].tap()
        
        app.staticTexts["Stage of Change"].tap()
        app.buttons["StageOfChangeButton:a"].tap()
        app.navigationBars.buttons["BackButton"].tap()
        XCTAssert(app.buttons["Stage of Change, A"].waitForExistence(timeout: 1))
        
        let continueButton = app.buttons["Continue"]
        while !continueButton.exists {
            app.swipeUp()
        }
        continueButton.tap()
    }
    
    
    private func navigateFinalOnboardingStep(signUpForExtraTrial: Bool) {
        XCTAssert(app.staticTexts["Welcome to My Heart Counts"].waitForExistence(timeout: 2))
        do {
            let element = app.staticTexts.matching("label CONTAINS %@", "After your baseline week, you'll begin the 2-week trial").element
            if signUpForExtraTrial {
                XCTAssert(element.waitForExistence(timeout: 2))
            } else {
                XCTAssert(element.waitForNonExistence(timeout: 2))
            }
        }
        app.buttons["Start"].tap()
        XCTAssert(app.staticTexts["Today's Tasks"].waitForExistence(timeout: 10))
    }
}


extension Locale.Region {
    func name(includeEmoji: Bool = false) -> String? {
        switch (includeEmoji, self) {
        case (false, .unitedStates):
            "United States"
        case (true, .unitedStates):
            "🇺🇸 United States"
        case (false, .unitedKingdom):
            "United Kingdom"
        case (true, .unitedKingdom):
            "🇬🇧 United Kingdom"
        case (false, .germany):
            "Germany"
        case (true, .germany):
            "🇩🇪 Germany"
        default:
            nil
        }
    }
}
