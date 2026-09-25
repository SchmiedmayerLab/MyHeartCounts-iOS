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
import XCTGroveAccount
import XCTGroveNotifications
import XCTHealthKit


@MainActor
struct OnboardingNavigator { // swiftlint:disable:this type_body_length
    enum ConsentPresenceCheck {
        case assertPresent
        case assertSkipped
        case dontCare
    }
    
    let testCase: MHCTestCase
    
    private var app: XCUIApplication {
        testCase.app
    }
    
    
    func navigateOnboardingFlowUntilHealthKit(
        region: Locale.Region,
        name: PersonNameComponents,
        credentials: SetupTestEnvironmentConfig.Credentials,
        signUpForExtraTrial: Bool,
        consentPresenceCheck: ConsentPresenceCheck
    ) throws {
        navigateWelcome()
        try navigateEligibility(region: region)
        try navigateSignup(name: name, credentials: credentials)
        let consentFlowIndicator = app.staticTexts["Study Overview & Participation"]
        let noConsentFlowIndicator = app.staticTexts["HealthKit Access"]
        switch consentPresenceCheck {
        case .assertPresent:
            XCTAssert(consentFlowIndicator.waitForExistence(timeout: 5))
        case .assertSkipped:
            XCTAssertFalse(consentFlowIndicator.waitForExistence(timeout: 5))
            XCTAssert(noConsentFlowIndicator.waitForExistence(timeout: 5))
        case .dontCare:
            break
        }
        if consentFlowIndicator.waitForExistence(timeout: 5) {
            navigateOnboardingDisclaimers()
            navigateConsentComprehension()
            navigateConsent(expectedName: name, signUpForExtraTrial: signUpForExtraTrial)
        }
        XCTAssert(app.staticTexts["HealthKit Access"].waitForExistence(timeout: 10))
    }
    
    func navigateFullOnboardingFlow(
        region: Locale.Region,
        name: PersonNameComponents,
        credentials: SetupTestEnvironmentConfig.Credentials,
        signUpForExtraTrial: Bool,
        consentPresenceCheck: ConsentPresenceCheck
    ) throws {
        try navigateOnboardingFlowUntilHealthKit(
            region: region,
            name: name,
            credentials: credentials,
            signUpForExtraTrial: signUpForExtraTrial,
            consentPresenceCheck: consentPresenceCheck
        )
        navigateHealthKitAccess()
        navigateHealthRecordsIfNecessary()
        navigateWorkoutPreferences()
        navigateNotificationsIfNecessary()
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
    
    
    func navigateSignup(name: PersonNameComponents, credentials: SetupTestEnvironmentConfig.Credentials) throws {
        XCTAssert(app.staticTexts["Your Account"].waitForExistence(timeout: 10))
        let isLoggedIn = app.staticTexts
            .matching("label BEGINSWITH %@", "You are already logged in")
            .element
            .waitForExistence(timeout: 2)
        if !isLoggedIn {
            defer {
                app.dismissSavePasswordAlert(timeout: 10)
            }
            try app.login(email: credentials.username, password: credentials.password)
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
            try app.fillSignupForm(email: credentials.username, password: credentials.password, name: name)
            XCTAssert(app.collectionViews.firstMatch.buttons["Signup"].isEnabled)
            app.collectionViews.firstMatch.buttons["Signup"].tap()
        } else {
            if let firstName = name.givenName, let lastName = name.familyName {
                XCTAssert(app.staticTexts["\(firstName) \(lastName)"].waitForExistence(timeout: 2))
            }
            XCTAssert(app.staticTexts[credentials.username].waitForExistence(timeout: 2))
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
    
    
    func navigateConsent(expectedName: PersonNameComponents?, signUpForExtraTrial: Bool) { // swiftlint:disable:this function_body_length
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
    
    
    func navigateHealthRecordsIfNecessary() {
        // only included if Health Records are actually available
        if app.staticTexts["Health Records"].waitForExistence(timeout: 2) {
            navigateHealthRecords()
        }
    }
    
    private func navigateHealthRecords() {
        let title = app.staticTexts["Health Records"]
        XCTAssert(title.waitForExistence(timeout: 2))
        app.buttons["Review Permissions"].tap()
        testCase.handleHealthRecordsAuthorization()
        XCTAssert(title.waitForNonExistence(timeout: 10)) // give it some time to complete the auth
    }
    
    
    func navigateNotificationsIfNecessary() {
        // this step is skipped if sufficient permissions have already been granted
        if app.staticTexts["Notifications"].waitForExistence(timeout: 2) {
            navigateNotifications()
        }
    }
    
    private func navigateNotifications() {
        XCTAssert(app.staticTexts["Notifications"].waitForExistence(timeout: 2))
        app.buttons["Allow Notifications"].tap()
        app.confirmNotificationAuthorization()
    }
    
    
    func navigateWorkoutPreferences() {
        XCTAssert(app.staticTexts["Workout Preference"].waitForExistence(timeout: 2))
        XCTAssert(app.staticTexts["Cycling"].waitForExistence(timeout: 2))
        app.staticTexts["Cycling"].tap()
        app.swipeUp()
        app.buttons["Continue"].tap()
    }
    
    
    private func navigateDemographics() {
        let navigator = DemographicsNavigator(testCase: testCase)
        navigator.fillInDemographics()
        let continueButton = app.buttons["Continue"]
        while !continueButton.exists {
            app.swipeUp()
        }
        continueButton.tap()
    }
    
    
    private func navigateFinalOnboardingStep(signUpForExtraTrial: Bool) {
        XCTAssert(app.staticTexts["Welcome to My Heart Counts"].waitForExistence(timeout: 2))
        do {
            app.swipeUp()
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
