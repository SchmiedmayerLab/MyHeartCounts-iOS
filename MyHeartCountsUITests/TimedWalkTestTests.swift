//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFoundation
import MyHeartCountsShared
import XCTest


final class TimedWalkTestTests: MHCTestCase {
    private enum WalkRunTestKind: String {
        case sixMWT = "Six-Minute Walk Test"
        case twelveMRT = "12-Minute Run Test"
    }
    
    
    private var timedWalkTestDistance: String {
        switch appLocale.measurementSystem {
        case .us:
            "2,762 ft"
        default:
            "842 m"
        }
    }
    
    
    /// Tests the siz minute walk test, and the display of past tests.
    func test6MWT() throws {
        try _testTimedWalkRunTest(kind: .sixMWT)
    }
    
    
    /// Tests the 12 minute run test, and the display of past tests.
    func test12MRT() throws {
        try _testTimedWalkRunTest(kind: .twelveMRT)
    }
    
    
    // also tests the Timed Walk Test UI
    func testCompleteScheduledTaskViaAlwaysAvailableMenu() throws {
        try launchAppAndEnrollIntoStudy()
        goToTab(.upcoming)
        
        let completionMessage = app.collectionViews.staticTexts["Six-Minute Walk Test, Completed"]
        
        do {
            var numTries = 0
            while numTries < 10, !app.collectionViews.buttons["Take Test: Six-Minute Walk Test"].waitForExistence(timeout: 2) {
                app.swipeUp()
                numTries += 1
            }
        }
        XCTAssert(app.collectionViews.buttons["Take Test: Six-Minute Walk Test"].waitForExistence(timeout: 2))
        XCTAssertFalse(completionMessage.exists)
        
        app.navigationBars["Tasks"].buttons["Perform Always Available Task"].tap()
        XCTAssert(app.buttons["Six-Minute Walk Test"].waitForExistence(timeout: 2))
        app.buttons["Six-Minute Walk Test"].tap()
        XCTAssert(app.buttons["Start Test"].waitForExistence(timeout: 2))
        app.buttons["Start Test"].tap()
        handleMotionAndFitnessAccessPrompt(timeout: .seconds(2))
        XCTAssert(app.staticTexts["Test Complete"].waitForExistence(timeout: 15))
        XCTAssert(app.staticTexts["Steps, 624"].exists)
        XCTAssert(app.staticTexts["Distance, \(timedWalkTestDistance)"].exists)
        app.navigationBars.buttons["Close"].tap()
        XCTAssert(completionMessage.exists)
    }
    
    
    private func _testTimedWalkRunTest(kind: WalkRunTestKind) throws {
        try launchAppAndEnrollIntoStudy()
        goToTab(.heartHealth)
        app.swipeUp()
        app.swipeUp()
        app.swipeUp()
        app.staticTexts["Past Timed Walk/Run Test Results"].tap()
        sleep(for: .seconds(1))
        
        let testCellPred = NSPredicate(format: "label LIKE '\(kind.rawValue), *'")
        var numTests: Int {
            app.buttons.matching(testCellPred).count
        }
        let numTestsBefore = numTests
        
        let assertTestDetails = { [self] in
            XCTAssert(app.staticTexts["Steps, 624"].waitForExistence(timeout: 2))
            XCTAssert(app.staticTexts["Distance, \(timedWalkTestDistance)"].waitForExistence(timeout: 2))
            let vo2MaxLabel = app.staticTexts["VO₂ max (estimate), 7.5 mL/kg·min"]
            switch kind {
            case .sixMWT:
                XCTAssertFalse(vo2MaxLabel.exists)
            case .twelveMRT:
                XCTAssert(vo2MaxLabel.exists)
            }
        }
        
        if case let button = app.buttons.element(matching: testCellPred),
           button.waitForExistence(timeout: 2) {
            button.firstMatch.tap()
            XCTAssert(app.navigationBars[kind.rawValue].waitForExistence(timeout: 2))
            assertTestDetails()
            app.navigationBars[kind.rawValue].buttons["BackButton"].tap()
        }
        
        app.buttons[kind.rawValue].tap()
        app.swipeUp()
        app.buttons["Start Test"].tap()
        handleMotionAndFitnessAccessPrompt(timeout: .seconds(2))
        XCTAssert(app.staticTexts["Test Complete"].waitForExistence(timeout: 10))
        assertTestDetails()
        app.otherElements["MHC.TimedWalkTestView"].navigationBars.buttons["Close"].tap()
        let numTestsAfter = numTests
        XCTAssertEqual(numTestsAfter, numTestsBefore + 1)
    }
    
    
    func testRecoverTimedWalkTest() throws {
        try launchAppAndEnrollIntoStudy()
        goToTab(.upcoming)
        
        app.navigationBars["Tasks"].buttons["Perform Always Available Task"].tap()
        XCTAssert(app.buttons["Six-Minute Walk Test"].waitForExistence(timeout: 2))
        app.buttons["Six-Minute Walk Test"].tap()
        XCTAssert(app.buttons["Start Test"].waitForExistence(timeout: 2))
        app.buttons["Start Test"].tap()
        handleMotionAndFitnessAccessPrompt(timeout: .seconds(2))
        XCTAssert(app.staticTexts["Your 6-Minute Walk Test is in progress."].waitForExistence(timeout: 5))
        app.terminate()
        try launchAppAndEnrollIntoStudy(
            testEnvironmentConfig: .init(resetExistingData: false, loginAndEnroll: .skip),
            skipGoingToHomeTab: true
        )
        XCTAssert(app.staticTexts["Your 6-Minute Walk Test is in progress."].waitForExistence(timeout: 5))
    }
}


extension MHCTestCase {
    func handleMotionAndFitnessAccessPrompt(timeout: Duration) {
        let app = XCUIApplication.springboard
        let alert = app.alerts.element(matching: "label LIKE %@", "“*” would like to access your Motion & Fitness activity.")
        if alert.waitForExistence(timeout: timeout.timeInterval) {
            // wait a little longer. sometimes the "exists" above resolves to true while the alert is still being presented,
            // in which case the tap is a little too early and doesn't actually get registered.
            let allowButton = alert.buttons["Allow"]
            XCTAssert(allowButton.wait(for: \.isHittable, toEqual: true, timeout: 5))
            allowButton.tap()
        }
    }
}
