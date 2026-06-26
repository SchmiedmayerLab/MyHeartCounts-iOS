//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

// swiftlint:disable multiline_function_chains function_body_length

@_spi(TestingSupport)
import SpeziHealthKit
import SpeziLocalization
import XCTest
import XCTestExtensions


final class ScheduledTaskTests: MHCTestCase, @unchecked Sendable {
    @MainActor
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
        
        try navigateResearchKitQuestionnaire(title: "Heart Risk", steps: [
            // initial page
            .init(actions: [.continue]),
            // Smoking Question
            .init(actions: [
                .selectOption(title: "Never smoked/vaped")
            ]),
            // Diabetes
            .init(actions: [
                .selectOption(title: "No")
            ]),
            // Risk Factor Medication
            .init(actions: [
                .selectOption(title: "None of the above")
            ]),
            // Heart Disease Diagnoses
            .init(actions: [
                .selectOption(title: "None of the above"),
                .scrollDown
            ]),
            // Vascular Disease Diagnosis
            .init(actions: [
                .selectOption(title: "None of the above")
            ]),
            // Medical History
            .init(actions: [
                .selectOption(title: "None of the above")
            ]),
            // Diagnosis for primary condition
            .init(actions: []),
            // Systolic blood pressure
            .init(actions: [
                .enterValue("69", into: "Tap to answer,  mm[Hg]")
            ]),
            // Diastolic blood pressure
            .init(actions: [
                .enterValue("69", into: "Tap to answer,  mm[Hg]")
            ]),
            // 2nd-most-recent systolic blood pressure
            .init(actions: [
                .enterValue("69", into: "Tap to answer,  mm[Hg]")
            ]),
            // fasting blood glucose
            .init(actions: [
                .enterValue("100", into: "Tap to answer,  mg/dL")
            ]),
            // HbA1C
            .init(actions: [
                .enterValue("9", into: "Tap to answer,  %")
            ]),
            // HDL cholesterol
            .init(actions: [
                .enterValue("50", into: "Tap to answer,  mg/dL")
            ]),
            // LDL cholesterol
            .init(actions: [
                .enterValue("50", into: "Tap to answer,  mg/dL")
            ]),
            // total cholesterol
            .init(actions: [
                .enterValue("100", into: "Tap to answer,  mg/dL")
            ]),
            // final step.
            .init(actions: [.continue])
        ])
        
        sleep(for: .seconds(10))
        
        app.navigationBars["Debug Options"].buttons["BackButton"].tap()
        app.navigationBars["Account Overview"].buttons["Close"].tap()
        
        goToTab(.heartHealth)
        app.swipeUp()
        if !HealthKit.needsBloodPressureAuthFlowFix {
            app.buttons["Blood Pressure"].tap()
            XCTAssert(app.collectionViews.staticTexts["Most Recent Sample: 69 over 69"].waitForExistence(timeout: 2))
            app.buttons["Close"].tap()
        }
        app.buttons["Fasting Blood Glucose"].tap() // fasting blood glucose value
        XCTAssert(app.collectionViews.staticTexts["Most Recent Sample: 100 mg/dL"].waitForExistence(timeout: 2))
    }
}


extension MHCTestCase {
    /// A Step within a ResearchKit questionnaire, i.e. one page with one or more questions.
    struct ResearchKitQuestionnaireStep {
        enum Action {
            case `continue`
            case selectOption(title: String, questionId: String? = nil)
            case enterValue(_ value: String, into: String)
            case scrollDown
            case scrollUp
            /// Special action that doesn't interact with the UI, but instead simply dumps the current state of the accessibility to stdout.
            case dumpAccessibilityTree(`continue`: Bool)
            /// Cancels the questionnaire.
            case cancel
            /// Performs a custom action.
            case custom(@MainActor () throws -> Void)
        }
        let actions: [Action]
    }
    
    
    @MainActor
    func navigateResearchKitQuestionnaire( // swiftlint:disable:this cyclomatic_complexity
        title: String?,
        steps: [ResearchKitQuestionnaireStep]
    ) throws {
        if let title {
            XCTAssert(app.staticTexts.element(
                matching: NSPredicate(format: "identifier = %@ AND label = %@", "ORKStepContentView_titleLabel", title)
            ).waitForExistence(timeout: 2))
            XCTAssert(app.staticTexts.element(
                matching: "identifier = %@ AND label = %@", "ORKStepContentView_titleLabel", title
            ).waitForExistence(timeout: 2))
        }
        steps: for step in steps {
            for action in step.actions {
                switch action {
                case .continue:
                    let button = app.buttons.matching(identifier: "ORKContinueButton.Next").element
                    XCTAssert(button.waitForExistence(timeout: 1))
                    button.tap()
                    continue steps
                case let .selectOption(title, questionId):
                    let cell = if let questionId {
                        app.cells.matching("identifier BEGINSWITH %@ && label = %@", questionId, title).element
                    } else {
                        app.cells[title]
                    }
                    XCTAssert(cell.exists)
                    cell.tap()
                case .scrollDown:
                    app.swipeUp()
                case .scrollUp:
                    app.swipeDown()
                case let .enterValue(value, textFieldLabel):
                    let textField = app.textFields[textFieldLabel]
                    XCTAssert(textField.exists)
                    textField.tap()
                    textField.typeText(value)
                    app.toolbars.buttons["Done"].tap()
                case .dumpAccessibilityTree(let `continue`):
                    print(app.debugDescription)
                    if !`continue` {
                        fatalError() // swiftlint:disable:this fatal_error_message
                    }
                case .cancel:
                    let title = try lookupLocalizedString("Cancel")
                    let button = app.navigationBars["ORKFormStepView"].buttons[title]
                    XCTAssert(button.waitForExistence(timeout: 2))
                    button.tap()
                    return
                case .custom(let action):
                    try action()
                }
            }
            app.buttons.matching(identifier: "ORKContinueButton.Next").element.tap()
        }
    }
}
