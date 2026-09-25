//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFoundation
import XCTest
import XCTHealthKit


/// Allows for dynamically interacting with the `DeomgraphicsForm` in UI tests.
///
/// Currently only supports filling out the entire form at once;
/// the plan is to add more granular per-field support, and support for the different regions, and awareness of different fields' optionality in the future.
@MainActor
struct DemographicsNavigator {
    private let testCase: MHCTestCase
    private var app: XCUIApplication {
        testCase.app
    }
    private var form: XCUIElement {
        app.collectionViews["DemographicsForm"]
    }
    
    init(testCase: MHCTestCase) {
        self.testCase = testCase
    }
    
    func performTestingSupportAction(_ title: String) {
        let menuButton = app.navigationBars["Demographics"].buttons["Testing Support"]
        XCTAssert(menuButton.waitForExistence(timeout: 1))
        menuButton.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5)).tap()
        XCTAssert(app.buttons[title].waitForExistence(timeout: 1))
        app.buttons[title].tap()
    }
    
    
    func fillInDemographics( // swiftlint:disable:this function_body_length
        skipReferralSource: Bool = false
    ) {
        XCTAssert(app.staticTexts["Demographics"].waitForExistence(timeout: 2))
        
        XCTAssert(app.navigationBars["Demographics"].waitForExistence(timeout: 1))
        XCTAssert(app.navigationBars.staticTexts["Demographics"].waitForExistence(timeout: 1))
        performTestingSupportAction("Add Height & Weight Samples")
        app.handleHealthKitAuthorization()
        app.buttons["Read from Health App"].tap()
        do {
            let dobCell = form.cells.containing(.staticText, identifier: "Date of Birth")
            let dobMissingResponseText = dobCell.staticTexts["Missing Response"]
            if dobMissingResponseText.waitForExistence(timeout: 5) {
                // HealthKit did not provide a DoB
                performTestingSupportAction("Supply Test DoB")
                XCTAssert(dobMissingResponseText.waitForNonExistence(timeout: 2))
            } else {
                // HealthKit did provide a DoB
                XCTAssert(
                    app.datePickers.matching("label = %@ AND value = %@", "Date of Birth", "1998-06-02").element.waitForExistence(timeout: 2)
                )
            }
        }
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
        
        if !skipReferralSource {
            fillInReferralSourceOption("Friend")
        }
    }
    
    
    func fillInReferralSourceOption(_ title: String) {
        form.swipeUp()
        form.swipeUp()
        app.staticTexts["Referral Source"].tap()
        let optionButton = app.buttons.matching("label CONTAINS[c] %@", title).firstMatch
        let fullOptionTitle = optionButton.label
        if !optionButton.isSelected {
            optionButton.tap()
        }
        app.navigationBars.buttons["BackButton"].tap()
        XCTAssert(form.buttons["Referral Source, \(fullOptionTitle)"].waitForExistence(timeout: 2))
    }
}
