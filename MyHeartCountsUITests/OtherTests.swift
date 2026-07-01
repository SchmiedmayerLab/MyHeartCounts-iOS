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
    
    
    /// Tests that passing `testEnvironmentConfig: .init(resetExistingData: false, loginAndEnroll: true)` to
    /// `launchAppAndEnrollIntoStudy` behaves properly (ie, we are logged in and the data from the previous launch remains).
    @MainActor
    func testLaunchKeepingData() throws {
        try launchAppAndEnrollIntoStudy()
        XCTAssert(app.staticTexts["Completed"].waitForNonExistence(timeout: 2))
        app.buttons["Read Article: Welcome to My Heart Counts"].tap()
        app.navigationBars.buttons["Close"].tap()
        XCTAssert(app.staticTexts["Completed"].waitForExistence(timeout: 2))
        app.terminate()
        
        try launchAppAndEnrollIntoStudy(
            testEnvironmentConfig: .init(resetExistingData: false, loginAndEnroll: true),
            skipHealthPermissionsHandling: true,
            skipGoingToHomeTab: true
        )
        sleep(for: .seconds(100))
        XCTAssert(app.staticTexts["Completed"].waitForExistence(timeout: 5))
    }
}
