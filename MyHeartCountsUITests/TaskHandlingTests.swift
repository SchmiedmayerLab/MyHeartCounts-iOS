//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import XCTest
import XCTHealthKit


final class TaskHandlingTests: MHCTestCase, @unchecked Sendable {
    func testECG() throws {
        try launchAppAndEnrollIntoStudy()
        goToTab(.upcoming)
        app.swipeUp()
        
        let completionMessage = app.collectionViews.staticTexts["ECG, Completed"]
        XCTAssert(app.collectionViews.buttons["Take ECG"].waitForExistence(timeout: 2))
        XCTAssertFalse(completionMessage.exists)
        app.navigationBars["Tasks"].buttons["Perform Always Available Task"].tap()
        XCTAssert(app.buttons["ECG"].waitForExistence(timeout: 2))
        app.buttons["ECG"].tap()
        
        XCTAssert(app.staticTexts["Taking an ECG with Your Apple Watch"].waitForExistence(timeout: 2))
        try launchAndAddSample(healthApp: .healthApp, .electrocardiogram())
        app.activate()
        XCTAssert(app.staticTexts["Success"].waitForExistence(timeout: 2))
        XCTAssert(app.staticTexts["Your ECG has successfully been recorded"].waitForExistence(timeout: 2))
        app.buttons["OK"].tap()
        
        XCTAssert(app.staticTexts["Your ECG has successfully been recorded"].waitForNonExistence(timeout: 2))
        XCTAssert(completionMessage.waitForExistence(timeout: 2))
    }
    
    
    func testHomeTabTaskSheetLifetime() throws {
        try launchAppAndEnrollIntoStudy()
        goToTab(.home)
        app.swipeUp()
        app.buttons["Answer Survey: Diet"].firstMatch.tap()
        let dietIntroTextElement = app.staticTexts.element(
            matching: "label BEGINSWITH %@", "This questionnaire is designed to allow you to assess the nutritional value of your diet."
        )
        XCTAssert(dietIntroTextElement.waitForExistence(timeout: 2))
        XCUIDevice.shared.press(.home)
        sleep(for: .seconds(2))
        app.activate()
        XCTAssert(app.wait(for: .runningForeground, timeout: 2))
        XCTAssert(dietIntroTextElement.waitForExistence(timeout: 2))
    }
}
