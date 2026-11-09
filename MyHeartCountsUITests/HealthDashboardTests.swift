//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

@_spi(TestingSupport)
import GroveHealthKit
import MyHeartCountsShared
import XCTest
import XCTestExtensions
import XCTGroveQuestionnaire
import XCTHealthKit


class HealthDashboardTests: MHCTestCase, @unchecked Sendable {
    func testHealthDashboardDataEntryBMIDirect() throws {
        let value = Int.random(in: 20...50)
        try launchAppAndEnrollIntoStudy()
        goToTab(.heartHealth)
        XCTAssert(app.buttons["Body Mass Index"].waitForExistence(timeout: 2))
        app.buttons["Body Mass Index"].tap()
        XCTAssert(app.navigationBars["Body Mass Index"].buttons["Add Data"].waitForExistence(timeout: 2))
        app.navigationBars["Body Mass Index"].buttons["Add Data"].tap()
        
        XCTAssert(app.navigationBars["Enter BMI"].waitForExistence(timeout: 2))
        app.segmentedControls.buttons["BMI"].tap()
        
        let doneButton = app.navigationBars["Enter BMI"].buttons["Save"]
        XCTAssertFalse(doneButton.isEnabled)
        let textField = app.textFields["QuantityDataEntry:Body Mass Index"]
        XCTAssert(textField.waitForExistence(timeout: 2))
        textField.tap()
        textField.typeText("\(value)")
        XCTAssert(doneButton.wait(for: \.isEnabled, toEqual: true, timeout: 1))
        doneButton.tap()
        
        XCTAssert(app.staticTexts["Most Recent Sample: \(value)"].waitForExistence(timeout: 5))
    }
    
    
    func testHealthDashboardDataEntryBMIIndirectMetric() throws {
        try launchAppAndEnrollIntoStudy(
            heightEntryUnitOverride: .cm,
            weightEntryUnitOverride: .kg
        )
        goToTab(.heartHealth)
        app.buttons["Body Mass Index"].tap()
        app.navigationBars["Body Mass Index"].buttons["Add Data"].tap()
        
        let weightTextField = app.textFields["QuantityDataEntry:Weight"]
        weightTextField.tap()
        weightTextField.typeText("67")
        
        let heightTextField = app.textFields["QuantityDataEntry:Height"]
        heightTextField.tap()
        heightTextField.typeText("186")
        
        app.navigationBars["Enter BMI"].buttons["Save"].tap()
        XCTAssert(app.staticTexts.element(matching: "label MATCHES %@", "Most Recent Sample: 19.37").waitForExistence(timeout: 5))
    }
    
    
    func testHealthDashboardDataEntryBMIIndirectUSUnits() throws {
        try launchAppAndEnrollIntoStudy(
            heightEntryUnitOverride: .feet,
            weightEntryUnitOverride: .lbs
        )
        goToTab(.heartHealth)
        app.buttons["Body Mass Index"].tap()
        app.navigationBars["Body Mass Index"].buttons["Add Data"].tap()
        
        let weightTextField = app.textFields["QuantityDataEntry:Weight"]
        weightTextField.tap()
        weightTextField.typeText("147.7")
        
        app.staticTexts["MHC:HeightRow"].tap()
        let feetPicker = app.pickers["FeetPicker"].pickerWheels.element
        let inchesPicker = app.pickers["InchesPicker"].pickerWheels.element
        XCTAssert(feetPicker.waitForExistence(timeout: 2))
        XCTAssert(inchesPicker.waitForExistence(timeout: 2))
        func setPicker(_ picker: XCUIElement, to value: String) {
            for _ in 0..<7 {
                picker.adjust(toPickerWheelValue: value)
                sleep(for: .seconds(0.5))
                if picker.value as? String == value {
                    return
                }
            }
        }
        setPicker(feetPicker, to: "6 ft")
        setPicker(inchesPicker, to: "1 in")
        XCTAssert(app.staticTexts["Height, 6‘ 1“"].waitForExistence(timeout: 2))
        
        app.navigationBars["Enter BMI"].buttons["Save"].tap()
        XCTAssert(app.staticTexts.element(matching: "label MATCHES %@", "Most Recent Sample: 19.49").waitForExistence(timeout: 5))
    }
    
    
    func testBloodLipidsEntry() throws {
        let value = Int.random(in: 30..<400)
        
        try launchAppAndEnrollIntoStudy()
        goToTab(.heartHealth)
        app.buttons["LDL Cholesterol"].tap()
        app.navigationBars["LDL Cholesterol"].buttons["Add Data"].tap()
        
        let textField = app.textFields["QuantityDataEntry:LDL Cholesterol"]
        XCTAssert(textField.waitForExistence(timeout: 2))
        textField.typeText("\(value)")
        
        app.navigationBars["Enter LDL Cholesterol"].buttons["Save"].tap()
        XCTAssert(app.staticTexts["Most Recent Sample: \(value) mg/dL"].waitForExistence(timeout: 4))
    }
    
    
    func testNicotineExposureQuestionnaire() throws {
        try launchAppAndEnrollIntoStudy()
        goToTab(.heartHealth)
        
        XCTAssert(app.buttons["Nicotine Exposure"].waitForExistence(timeout: 2))
        app.buttons["Nicotine Exposure"].tap()
        
        XCTAssert(app.navigationBars["Nicotine Exposure"].buttons["Add Data"].waitForExistence(timeout: 2))
        
        app.navigationBars["Nicotine Exposure"].buttons["Add Data"].tap()
        XCTAssert(questionnaire.waitUntilPresented())
        questionnaire.question("dcb2277e-fe96-4f45-844a-ef58a9516380").select("Never smoked/vaped")
        questionnaire.submit()
        XCTAssert(questionnaire.waitUntilDismissed())
        XCTAssert(app.staticTexts["Most Recent Response: Never Smoked"].waitForExistence(timeout: 10))

        app.navigationBars["Nicotine Exposure"].buttons["Add Data"].tap()
        XCTAssert(questionnaire.waitUntilPresented())
        questionnaire.question("dcb2277e-fe96-4f45-844a-ef58a9516380").select("Quit >5 years ago")
        questionnaire.submit()
        XCTAssert(questionnaire.waitUntilDismissed())
        XCTAssert(app.staticTexts["Most Recent Response: Quit more than 5 years ago"].waitForExistence(timeout: 10))
    }


    func testNicotineExposureEntryViaScoreSheet() throws {
        try launchAppAndEnrollIntoStudy()
        goToTab(.heartHealth)
        // two components, so that the nicotine response is the third one, which makes the overall score appear
        enterBMIAndLDLCholesterol()

        let dashboardScore = app.buttons["MHC:OverallScore"]
        XCTAssert(dashboardScore.waitForExistence(timeout: 2))
        XCTAssert(
            app.buttons
                .element(matching: "identifier == %@ AND value BEGINSWITH %@", "MHC:OverallScore", "No Data")
                .waitForExistence(timeout: 5)
        )
        XCTAssertEqual(app.buttons["MHC:DashboardTile:Nicotine Exposure"].value as? String, "No Data")

        dashboardScore.tap()
        XCTAssert(app.navigationBars["Heart Health Score"].waitForExistence(timeout: 2))
        let sheetScore = app.descendants(matching: .any)["MHC:ScoreSheet:OverallScore"]
        XCTAssert(sheetScore.waitForExistence(timeout: 2))
        XCTAssertEqual(sheetScore.value as? String, "No Data")

        let addNicotineButton = app.buttons["MHC:ScoreSheet:AddData:Nicotine Exposure"]
        XCTAssert(addNicotineButton.waitForExistence(timeout: 2))
        addNicotineButton.tap()
        XCTAssert(questionnaire.waitUntilPresented())
        questionnaire.question("dcb2277e-fe96-4f45-844a-ef58a9516380").select("Never smoked/vaped")
        questionnaire.submit()
        XCTAssert(questionnaire.waitUntilDismissed())

        // the nicotine row moves from "Complete Your Score" to "Components With Data"
        XCTAssert(addNicotineButton.waitForNonExistence(timeout: 10))
        XCTAssert(app.buttons["MHC:ScoreSheet:Component:Nicotine Exposure"].waitForExistence(timeout: 2))
        // the overall score at the top of the sheet appears
        XCTAssert(
            app.descendants(matching: .any)
                .element(matching: "identifier == %@ AND value MATCHES %@", "MHC:ScoreSheet:OverallScore", "[0-9]+")
                .waitForExistence(timeout: 10)
        )
        let score = try XCTUnwrap(sheetScore.value as? String)

        app.navigationBars["Heart Health Score"].buttons["Close"].tap()
        XCTAssert(app.navigationBars["Heart Health Score"].waitForNonExistence(timeout: 2))
        // the dashboard shows the same overall score
        XCTAssert(
            app.buttons
                .element(matching: "identifier == %@ AND value MATCHES %@", "MHC:OverallScore", "\(score)([^0-9].*)?")
                .waitForExistence(timeout: 5)
        )
        // the nicotine tile shows the new response's score
        XCTAssert(
            app.buttons
                .element(matching: "identifier == %@ AND value MATCHES %@", "MHC:DashboardTile:Nicotine Exposure", "Score Result: [0-9]+ percent")
                .waitForExistence(timeout: 5)
        )
    }


    func testDietScoreProcessing() throws {
        // The survey contains multiple questions on one page and needs a dedicated UI-test flow.
        throw XCTSkip("TODO")
    }
    
    
    func testBloodPressureDataEntry() throws {
        guard !HealthKit.needsBloodPressureAuthFlowFix else {
            throw XCTSkip("Skipping bc of iOS 26.5.x Blood Pressure auth issue")
        }
            
        let systolic = Int.random(in: 100...140)
        let diastolic = Int.random(in: 60...90)
        
        try launchAppAndEnrollIntoStudy()
        goToTab(.heartHealth)
        app.swipeUp()
        XCTAssert(app.buttons["Blood Pressure"].waitForExistence(timeout: 2))
        app.buttons["Blood Pressure"].tap()
        
        XCTAssert(app.navigationBars["Blood Pressure"].waitForExistence(timeout: 2))
        app.navigationBars["Blood Pressure"].buttons["Add Data"].tap()
        
        XCTAssert(app.navigationBars["Enter Blood Pressure"].waitForExistence(timeout: 2))
        
        app.textFields["QuantityDataEntry:Systolic Blood Pressure"].tap()
        app.textFields["QuantityDataEntry:Systolic Blood Pressure"].typeText("\(systolic)")
        app.textFields["QuantityDataEntry:Diastolic Blood Pressure"].tap()
        app.textFields["QuantityDataEntry:Diastolic Blood Pressure"].typeText("\(diastolic)")
        
        app.navigationBars["Enter Blood Pressure"].buttons["Save"].tap()
        
        XCTAssert(app.staticTexts["Most Recent Sample: \(systolic) over \(diastolic)"].waitForExistence(timeout: 5))
    }
    
    
    func testQuantityInputBounds() throws {
        try launchAppAndEnrollIntoStudy()
        goToTab(.heartHealth)
        
        app.buttons["Blood Pressure"].tap()
        app.navigationBars["Blood Pressure"].buttons["Add Data"].tap()
        
        let systolicErrorMessage = app.staticTexts["Only values from 60 to 250 are allowed"]
        let diastolicErrorMessage = app.staticTexts["Only values from 30 to 150 are allowed"]
        
        let systolicTextField = app.textFields["QuantityDataEntry:Systolic Blood Pressure"]
        let diastolicTextField = app.textFields["QuantityDataEntry:Diastolic Blood Pressure"]
        
        XCTAssertFalse(systolicErrorMessage.exists)
        XCTAssertFalse(diastolicErrorMessage.exists)
        
        XCTAssertFalse(systolicErrorMessage.exists)
        systolicTextField.tap()
        systolicTextField.typeText("50")
        XCTAssert(systolicErrorMessage.waitForExistence(timeout: 1))
        try systolicTextField.delete(count: 2, options: .skipTextFieldSelection)
        XCTAssert(systolicErrorMessage.waitForNonExistence(timeout: 1))
        systolicTextField.typeText("75")
        XCTAssertFalse(systolicErrorMessage.exists)
        try systolicTextField.delete(count: 2, options: .skipTextFieldSelection)
        systolicTextField.typeText("100")
        XCTAssert(systolicErrorMessage.waitForNonExistence(timeout: 1))
        systolicTextField.typeText("0")
        XCTAssert(systolicErrorMessage.waitForExistence(timeout: 1))
        
        XCTAssertFalse(diastolicErrorMessage.exists)
        diastolicTextField.tap()
        diastolicTextField.typeText("20")
        XCTAssert(diastolicErrorMessage.waitForExistence(timeout: 1))
        try diastolicTextField.delete(count: 2, options: .skipTextFieldSelection)
        XCTAssert(diastolicErrorMessage.waitForNonExistence(timeout: 1))
        diastolicTextField.typeText("75")
        XCTAssertFalse(diastolicErrorMessage.exists)
        try diastolicTextField.delete(count: 2, options: .skipTextFieldSelection)
        diastolicTextField.typeText("100")
        XCTAssert(diastolicErrorMessage.waitForNonExistence(timeout: 1))
        diastolicTextField.typeText("0")
        XCTAssert(diastolicErrorMessage.waitForExistence(timeout: 1))
        
        systolicTextField.tap()
        systolicTextField.typeKey(.rightArrow, modifierFlags: .alternate)
        systolicTextField.typeKey(.rightArrow, modifierFlags: .alternate)
        try systolicTextField.delete(count: 5, options: .skipTextFieldSelection)
        XCTAssert(systolicErrorMessage.waitForNonExistence(timeout: 2))
        
        diastolicTextField.tap()
        diastolicTextField.typeKey(.rightArrow, modifierFlags: .alternate)
        diastolicTextField.typeKey(.rightArrow, modifierFlags: .alternate)
        try diastolicTextField.delete(count: 5, options: .skipTextFieldSelection)
        XCTAssert(diastolicErrorMessage.waitForNonExistence(timeout: 2))
    }
    
    
    func testSleepSessionsSheet() throws {
        try launchAppAndEnrollIntoStudy(enableDebugMode: true, extraLaunchArgs: [
            "--dashboardConsiderAllSleepData"
        ])
        openAccountSheet()
        app.swipeUp()
        app.swipeUp()
        app.buttons["Debug"].tap()
        app.swipeUp()
        app.buttons["Add Sleep Sessions"].tap()
        app.handleHealthKitAuthorization()
        sleep(for: .seconds(2))
        app.navigationBars.buttons["BackButton"].tap()
        app.navigationBars.buttons["Close"].tap()
        goToTab(.heartHealth)
        app.swipeUp()
        app.buttons["Sleep"].tap()
        XCTAssert(app.staticTexts["Most Recent Night: 6 hours and 36 minutes"].waitForExistence(timeout: 5))
    }
}


extension HealthDashboardTests {
    /// Enters a BMI and an LDL cholesterol sample via the dashboard tiles, and returns to the dashboard.
    private func enterBMIAndLDLCholesterol() {
        XCTAssert(app.buttons["Body Mass Index"].waitForExistence(timeout: 2))
        app.buttons["Body Mass Index"].tap()
        XCTAssert(app.navigationBars["Body Mass Index"].buttons["Add Data"].waitForExistence(timeout: 2))
        app.navigationBars["Body Mass Index"].buttons["Add Data"].tap()
        XCTAssert(app.navigationBars["Enter BMI"].waitForExistence(timeout: 2))
        app.segmentedControls.buttons["BMI"].tap()
        let bmiTextField = app.textFields["QuantityDataEntry:Body Mass Index"]
        XCTAssert(bmiTextField.waitForExistence(timeout: 2))
        bmiTextField.tap()
        bmiTextField.typeText("23")
        let saveBMIButton = app.navigationBars["Enter BMI"].buttons["Save"]
        XCTAssert(saveBMIButton.wait(for: \.isEnabled, toEqual: true, timeout: 1))
        saveBMIButton.tap()
        XCTAssert(app.staticTexts["Most Recent Sample: 23"].waitForExistence(timeout: 5))
        app.navigationBars["Body Mass Index"].buttons["Close"].tap()

        XCTAssert(app.buttons["LDL Cholesterol"].waitForExistence(timeout: 2))
        app.buttons["LDL Cholesterol"].tap()
        XCTAssert(app.navigationBars["LDL Cholesterol"].buttons["Add Data"].waitForExistence(timeout: 2))
        app.navigationBars["LDL Cholesterol"].buttons["Add Data"].tap()
        let ldlTextField = app.textFields["QuantityDataEntry:LDL Cholesterol"]
        XCTAssert(ldlTextField.waitForExistence(timeout: 2))
        ldlTextField.typeText("100")
        app.navigationBars["Enter LDL Cholesterol"].buttons["Save"].tap()
        XCTAssert(app.staticTexts["Most Recent Sample: 100 mg/dL"].waitForExistence(timeout: 4))
        app.navigationBars["LDL Cholesterol"].buttons["Close"].tap()
    }
}
