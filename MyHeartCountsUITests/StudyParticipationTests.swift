//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import XCTest
import XCTestExtensions
import XCTHealthKit
import XCTSpeziAccount
import XCTSpeziNotifications


final class StudyParticipationTests: MHCTestCase, Sendable {
    func testStudyEnrollment() throws {
        try launchAppAndEnrollIntoStudy()
        openAccountSheet()
        XCTAssert(app.staticTexts["Leland Stanford"].waitForExistence(timeout: 1))
        XCTAssert(app.staticTexts["leland@stanford.edu"].waitForExistence(timeout: 1))
        XCTAssert(app.staticTexts["Study Participation"].waitForExistence(timeout: 1))
        XCTAssert(app.staticTexts["My Heart Counts"].waitForExistence(timeout: 1))
        XCTAssert(app.staticTexts["Improve your cardiovascular health"].waitForExistence(timeout: 1))
    }
}
