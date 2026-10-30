//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

@_spi(TestingSupport)
import GroveHealthKit
import GroveLocalization
import XCTest
import XCTestExtensions
import XCTGroveQuestionnaire


final class ScheduledTaskTests: MHCTestCase, Sendable {
    func testSurveyHealthDataExtraction() throws {
        try launchAppAndEnrollIntoStudy(enableDebugMode: true)
        openAccountSheet()
        XCTAssert(app.navigationBars["Account Overview"].waitForExistence(timeout: 2))
        app.swipeUp()
        
        app.buttons["Debug"].tap()
        app.swipeUp()
        XCTAssert(app.buttons["Answer Questionnaire"].waitForExistence(timeout: 2))
        app.buttons["Answer Questionnaire"].tap()
        XCTAssert(app.buttons["HeartRisk"].waitForExistence(timeout: 2))
        app.buttons["HeartRisk"].tap()
        
        XCTAssert(questionnaire.waitUntilPresented())
        // Asymmetric on purpose: equal components cannot tell a correct pairing from a swapped one.
        try questionnaire.question("7cec349c-495c-4ef6-834e-cc9708625736").enterNumber(118)
        try questionnaire.question("b25ac0aa-4528-47dc-951f-97f411ec5cc2").enterNumber(76)
        try questionnaire.question("7309938e-ea24-4e31-8427-82f3a1a44f83").enterNumber(100)
        questionnaire.submit()
        XCTAssert(questionnaire.waitUntilDismissed())
        
        sleep(for: .seconds(10))
        
        app.navigationBars["Debug Options"].buttons["BackButton"].tap()
        app.navigationBars["Account Overview"].buttons["Close"].tap()
        
        goToTab(.heartHealth)
        app.swipeUp()
        if !HealthKit.needsBloodPressureAuthFlowFix {
            app.buttons["Blood Pressure"].tap()
            XCTAssert(app.collectionViews.staticTexts["Most Recent Sample: 118 over 76"].waitForExistence(timeout: 2))
            app.buttons["Close"].tap()
        }
        app.buttons["Fasting Blood Glucose"].tap() // fasting blood glucose value
        XCTAssert(app.collectionViews.staticTexts["Most Recent Sample: 100 mg/dL"].waitForExistence(timeout: 2))
    }
}
