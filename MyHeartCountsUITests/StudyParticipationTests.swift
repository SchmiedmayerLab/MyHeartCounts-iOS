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


final class StudyParticipationTests: MHCTestCase, Sendable {
    func testStudyEnrollment() throws {
        let credentials: SetupTestEnvironmentConfig.Credentials = .random()
        try launchAppAndEnrollIntoStudy(
            testEnvironmentConfig: .init(resetExistingData: true, loginAndEnroll: .enable(credentials))
        )
        openAccountSheet()
        XCTAssert(app.staticTexts["Leland Stanford"].waitForExistence(timeout: 1))
        XCTAssert(app.staticTexts["\(credentials.username)"].waitForExistence(timeout: 1))
        XCTAssert(app.staticTexts["Study Participation"].waitForExistence(timeout: 1))
        XCTAssert(app.staticTexts["My Heart Counts"].waitForExistence(timeout: 1))
        XCTAssert(app.staticTexts["Improve your cardiovascular health"].waitForExistence(timeout: 1))
    }
}
