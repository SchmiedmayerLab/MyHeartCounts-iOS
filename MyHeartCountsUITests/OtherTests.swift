//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import HealthKit
import MyHeartCountsShared
import XCTest
import XCTestExtensions
import XCTHealthKit


final class OtherTests: MHCTestCase, @unchecked Sendable {
    @MainActor
    func testSkippingClinicalRecordsAuthorization() throws {
        guard MHCTestCase.enableHealthRecords else {
            throw XCTSkip("Health Records Testing disabled")
        }
        app.resetAuthorizationStatus(for: .health)
        app.delete(app: "My Heart Counts")
        try launchAppAndEnrollIntoStudy(
            skipHealthPermissionsHandling: true,
            skipGoingToHomeTab: true
        )
        XCTAssert(app.navigationBars["Health Access"].waitForExistence(timeout: 10))
        app.handleHealthKitAuthorization()
        XCTAssert(app.staticTexts["How Sharing Health Records Works"].waitForExistence(timeout: 20))
        app.navigationBars.buttons["Cancel"].tap()
        XCTAssert(app.staticTexts["Welcome to My Heart Counts"].waitForExistence(timeout: 20))
        
        app.terminate()
        try launchAppAndEnrollIntoStudy(
            testEnvironmentConfig: .init(resetExistingData: false, loginAndEnroll: false),
            skipHealthPermissionsHandling: true,
            skipGoingToHomeTab: true
        )
        XCTAssert(app.staticTexts["How Sharing Health Records Works"].waitForNonExistence(timeout: 20))
        XCTAssert(app.staticTexts["Welcome to My Heart Counts"].waitForExistence(timeout: 20))
    }
}
