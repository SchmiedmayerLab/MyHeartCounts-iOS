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
import XCTHealthKit


class HealthDashboardTests: MHCTestCase, @unchecked Sendable {
    @MainActor
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
        
        XCTAssert(app.staticTexts["Most Recent Sample: \(value)"].waitForExistence(timeout: 2))
    }
    
    
    @MainActor
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
    
    
    @MainActor
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
    
    
    @MainActor
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
    
    
    @MainActor
    func testNicotineExposureProcessing() throws {
        try launchAppAndEnrollIntoStudy()
        goToTab(.heartHealth)
        
        XCTAssert(app.buttons["Nicotine Exposure"].waitForExistence(timeout: 2))
        app.buttons["Nicotine Exposure"].tap()
        
        XCTAssert(app.navigationBars["Nicotine Exposure"].buttons["Add Data"].waitForExistence(timeout: 2))
        
        app.navigationBars["Nicotine Exposure"].buttons["Add Data"].tap()
        try navigateResearchKitQuestionnaire(title: "Dashboard - Smoking", steps: [ // NOTE: might want to rename the survey here?!
            .init(actions: [.selectOption(title: "Never smoked/vaped")])
        ])
        XCTAssert(app.staticTexts["Most Recent Response: Never Smoked"].waitForExistence(timeout: 10))
        
        app.navigationBars["Nicotine Exposure"].buttons["Add Data"].tap()
        try navigateResearchKitQuestionnaire(title: "Dashboard - Smoking", steps: [ // NOTE: might want to rename the survey here?!
            .init(actions: [.selectOption(title: "Quit >5 years ago")])
        ])
        XCTAssert(app.staticTexts["Most Recent Response: Quit more than 5 years ago"].waitForExistence(timeout: 10))
    }
    
    
    @MainActor
    func testDietScoreProcessing() throws {
        // not trivial bc the survey contains mutiple questions on a single page, and it's not easy to differentiate between them.
        throw XCTSkip("TODO")
//        try launchAppAndEnrollIntoStudy()
//        goToTab(.heartHealth)
//        
//        XCTAssert(app.buttons["Diet"].waitForExistence(timeout: 2))
//        app.buttons["Diet"].tap()
//        
//        XCTAssert(app.navigationBars["Diet"].waitForExistence(timeout: 2))
//        app.navigationBars["Diet"].buttons["Add Data"].tap()
//        
//        try app.navigateResearchKitQuestionnaire(title: "Diet", steps: [
//            .init(actions: [.continue]),
//        ])
    }
    
    
    @MainActor
    func testBloodPressureDataEntry() throws {
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
    
    
    @MainActor
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
    
    
    @MainActor
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
        XCTAssert(app.staticTexts["Most Recent Night: 6 hours and 36 minutes"].waitForExistence(timeout: 2))
    }
}
