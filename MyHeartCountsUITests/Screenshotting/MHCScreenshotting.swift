//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import SpeziLocalization
import UniformTypeIdentifiers
import XCTest
import XCTHealthKit


final class MHCScreenshotting: MHCTestCase, Sendable {
    private var screenshotsDir: URL! // swiftlint:disable:this implicitly_unwrapped_optional
    
    private var screenshotIdx = 0
    
    override func setUp() async throws {
        try await super.setUp()
        /// The URL of the `MyHeartCounts-iOS` repository.
        ///
        /// The full value of `#filePath` is e.g. `/Users/lukas/Developer/Spezi/MyHeartCounts-iOS/MyHeartCountsUITests/Screenshotting/MHCScreenshotting.swift`;
        /// we then need to remove the last 3 path components to get the root of the codebase.
        screenshotsDir = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "fastlane/screenshots", directoryHint: .isDirectory)
    }
    
    func recordScreenshot(_ name: String? = nil) throws {
        defer {
            screenshotIdx += 1
        }
        sleep(for: .seconds(0.5)) // give it some time to complete whatever animation might currently still be going on.
        let name = name ?? "\(screenshotIdx)_APP_IPHONE_67_\(screenshotIdx)"
        let pngData = XCUIScreen.main.screenshot().pngRepresentation
        let localeKey = try XCTUnwrap(LocalizationKey(locale: appLocale)).description
        let dir = screenshotsDir.appending(path: localeKey, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileUrl = dir.appendingPathComponent(name, conformingTo: .png)
        try pngData.write(to: fileUrl)
    }
}


extension MHCScreenshotting {
    func testTakeAppStoreScreenshots() throws {
        try runScreenshotsFlow(for: .enUS)
        try runScreenshotsFlow(for: .esES)
        try runScreenshotsFlow(for: .enUK)
    }
    
    
    private func runScreenshotsFlow(for locale: Locale) throws { // swiftlint:disable:this function_body_length
        screenshotIdx = 0 // reset at begin
        let isFirstRun = locale == .enUS
        try launchAppAndEnrollIntoStudy(
            skip: false,
            locale: locale,
            skipHealthPermissionsHandling: !isFirstRun,
            // the "go to home tab" thing implies checking for the on-screen existence of certain texts, which will fail if the language isn't english.
            // we instead manually go to the home tab.
            skipGoingToHomeTab: true,
            extraLaunchArgs: [
                "--dashboardConsiderAllSleepData"
            ],
            extraEnvironmentEntries: [
                "MHC_IS_TAKING_DEMO_SCREENSHOTS": "1"
            ]
        )
        
        /*
         screenshots:
         0: home tab (with completed task)
         1: dashboard
         2: survey
         3: sleep stats
         4: home screen nudge
         5: welcome article
         */
        
        goToTab(.home, timeout: 10) // give it a little extra time; the app might still be launching
//        try recordScreenshot("Home Tab 1")
        // open the "Welcome to My Heart Counts" article
        // works when only looking at the prefix, bc there is only a single article on the Home tab.
        app.buttons.matching("identifier BEGINSWITH %@", "Read Article: ").element.tap()
        try recordScreenshot("5_APP_IPHONE_67_5")
        app.navigationBars.buttons["Close"].tap()
        try recordScreenshot("0_APP_IPHONE_67_0")
        
        goToTab(.heartHealth)
        if isFirstRun { // only need to do this once
            openAccountSheet()
            app.swipeUp()
            app.buttons["Debug"].tap()
            app.swipeUp()
            app.buttons["Add Demo Data"].tap()
            app.handleHealthKitAuthorization(timeout: 10)
            sleep(for: .seconds(5)) // give it some time to add everything
            app.navigationBars["Debug Options"].buttons["BackButton"].tap()
            app.navigationBars.buttons["Close"].tap()
        }
        sleep(for: .seconds(2)) // give it some time to load
        try recordScreenshot("1_APP_IPHONE_67_1") // dashboard screenshot
        
        app.buttons["MHC:DashboardTile:Sleep"].tap()
        try recordScreenshot("3_APP_IPHONE_67_3")
        app.navigationBars.buttons["Close"].tap()
        
        goToTab(.home)
        app.swipeUp()
        // open the diet questionnaire
        // note: we make use of the fact here that the english and spanish titles have the same prefix "Diet" vs "Dieta".
        app.buttons.matching("identifier BEGINSWITH %@", "Answer Survey: Diet").element.tap()
        try navigateResearchKitQuestionnaire(title: nil, steps: [
            // initial page
            .init(actions: [.continue]),
            // "fruits and vegetables" page
            .init(actions: [.scrollDown, .continue]),
            // "fat" page
            .init(actions: [.scrollDown, .continue]),
            // "starchy foods" page
            .init(actions: [
                .selectOption(
                    title: try lookupLocalizedString("Yes"),
                    questionId: "055647aa-77aa-4877-81ae-40a2f08b8c5e"
                ),
                .selectOption(
                    title: try lookupLocalizedString("No"),
                    questionId: "784f7a2c-6ec8-414b-caa4-b59f1e8a6a1c"
                ),
                .scrollUp,
                .custom {
                    // survey screenshot
                    try self.recordScreenshot("2_APP_IPHONE_67_2")
                },
                .cancel
            ])
        ])
        
        // trigger nudge notification and take a screenshot
        do {
            openAccountSheet()
            app.swipeUp()
            app.buttons["Debug"].tap()
            app.buttons["Send Demo Nudge Notification"].tap()
            
            // lock the device
            XCUIDevice.shared.pressLockButton()
            // turn on the device (doesn't unlock)
            XCUIDevice.shared.press(.home)
            let springboard = XCUIApplication.springboard
            let notification = springboard.descendants(matching: .any)["NotificationShortLookView"]
            XCTAssert(notification.waitForExistence(timeout: 10))
            try recordScreenshot("4_APP_IPHONE_67_4")
            // dismiss the notification, so that the next screenshot (for the next language) only contains that
            notification.swipeLeft()
            let clearButton = springboard.buttons.matching("identifier = %@ && label = %@", "swipe-action-button-identifier", "Clear").element
            XCTAssert(clearButton.waitForExistence(timeout: 2))
            clearButton.tap()
        }
    }
}


extension MHCTestCase {
    /// Looks up the localized string `key` in the main app's localization catalogue, for app's current language.
    ///
    /// If no entry exists for the key, the key itself is returned.
    func lookupLocalizedString(_ key: String) throws -> String {
        try XCTUnwrap(app.mainBundle).localizedString(forKey: key, tables: [.default], localizations: [appLocale.language]) ?? key
    }
}
