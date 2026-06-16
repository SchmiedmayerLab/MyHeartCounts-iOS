//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

// swiftlint:disable implicitly_unwrapped_optional type_contents_order

import Foundation
import MHCStudyDefinitionExporter
import MyHeartCountsShared
import SpeziFoundation
import SpeziLocalization
import XCTest
import XCTestExtensions
import XCTHealthKit

/*
 Ideas for additional tests:
 - [dashboard] exercise mins vs step count (+ auto switch based on what's available!)
 - an onboarding test where we enter invalid values and get to the "you're not eligible" step
 */

/// The base class for all MHC UI tests.
///
/// This class sets up the ``app`` property, and provides the ``launchAppAndEnrollIntoStudy`` function.
class MHCTestCase: XCTestCase, @unchecked Sendable {
    static let loginCredentials = (email: "leland@stanford.edu", password: "StanfordRocks!")
    
    private static let tempDir = URL.temporaryDirectory.appending(component: "edu.stanford.MyHeartCounts.UITests", directoryHint: .isDirectory)
    
    @MainActor private(set) var app: XCUIApplication!
    @MainActor private(set) var studyBundleUrl: URL!
    @MainActor private(set) var appLocale: Locale!
    
    @MainActor
    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        if studyBundleUrl == nil {
            try FileManager.default.createDirectory(at: Self.tempDir, withIntermediateDirectories: true)
            studyBundleUrl = try export(to: Self.tempDir, as: .archive)
        }
    }
    
    @MainActor
    override func tearDown() async throws {
        try await super.tearDown()
        app.terminate()
        app = nil
        appLocale = nil
    }
    
    override class func tearDown() {
        try? FileManager.default.removeItem(at: Self.tempDir)
    }
    
    /// Launches the app and puts it in a state where the participant is logged in and enrolled into the study.
    ///
    /// - parameter enableDebugMode: Whether the app should force-enable its debug mode for this launch. Defaults to `false`.
    /// - parameter heightEntryUnitOverride: Allows overriding the unit the app will use when manually entering a height quantity.
    ///     Allowed values are `cm`, `feet`, or `nil` (the default).
    /// - parameter weightEntryUnitOverride: Allows overriding the unit the app will use when manually entering a weight quantity.
    ///     Allowed values are `kg`, `lbs`, or `nil` (the default).
    /// - parameter extraLaunchArgs: Additional arguments that will be appended to the app's launch arguments. `nil` values will be skipped.
    @MainActor
    func launchAppAndEnrollIntoStudy( // swiftlint:disable:this function_body_length
        skip: Bool = false,
        locale: Locale = .current,
        enableDebugMode: Bool = false,
        testEnvironmentConfig: SetupTestEnvironmentConfig = .init(resetExistingData: true, loginAndEnroll: true),
        enableHealthRecords: Bool = false, // temporarily disabled
        skipHealthPermissionsHandling: Bool = false,
        skipGoingToHomeTab: Bool = false,
        heightEntryUnitOverride: LaunchOptions.HeightInputUnitOverride = .none,
        weightEntryUnitOverride: LaunchOptions.WeightInputUnitOverride = .none,
        extraLaunchArgs: [String?] = [],
        extraEnvironmentEntries: [String: String] = [:]
    ) throws {
        if skip {
            throw XCTSkip()
        }
        app.launchArguments = Array {
            "--useFirebaseEmulator"
            testEnvironmentConfig.launchOptionArgs(for: .setupTestEnvironment)
            StudyBundleSelector.atUrl(studyBundleUrl).launchOptionArgs(for: .studyBundleSelector)
            "--disableAutomaticBulkHealthExport"
            enableDebugMode.launchOptionArgs(for: .forceEnableDebugMode)
            enableHealthRecords.launchOptionArgs(for: .enableHealthRecords)
            heightEntryUnitOverride.launchOptionArgs(for: .heightInputUnitOverride)
            weightEntryUnitOverride.launchOptionArgs(for: .weightInputUnitOverride)
        }
        app.launchArguments += extraLaunchArgs.compactMap(\.self)
        appLocale = locale
        app.launchArguments += [
            "-AppleLanguages", "(\(locale.language.minimalIdentifier))",
            "-AppleLocale", try XCTUnwrap(LocalizationKey(locale: locale)).description
        ]
        app.launchEnvironment["MHC_IS_BEING_UI_TESTED"] = "1"
        app.launchEnvironment.merge(extraEnvironmentEntries, using: .override)
        do {
            var msg = "Will launch app \(app.bundleIdentifier) with configuration:\n"
            msg += "argv:\n"
            for arg in app.launchArguments {
                msg += "    \(arg)\n"
            }
            msg += "env:\n"
            for (key, value) in app.launchEnvironment {
                msg += "    \(key) = \(value)\n"
            }
            print(msg)
        }
        app.launch()
        XCTAssert(app.wait(for: .runningForeground, timeout: 2))
        if !skipHealthPermissionsHandling {
            app.handleHealthKitAuthorization(timeout: 10) // Idea: maybe adjust this based on local vs CI?
            handleHealthRecordsAuthorization(
                healthRecordTypes: HealthRecordType.allCases,
                automaticallyShareUpdates: true,
                timeout: 10
            )
        }
        if !skipGoingToHomeTab {
            XCTAssert(app.tabBars.element.waitForExistence(timeout: 10))
            goToTab(.home)
            XCTAssert(app.staticTexts["My Heart Counts"].waitForExistence(timeout: 1))
            XCTAssert(app.staticTexts["Welcome to My Heart Counts"].exists)
            XCTAssertGreaterThanOrEqual(
                ["Diet", "Par-Q+", "Six-Minute Walk Test", "Heart Risk"].count {
                    app.staticTexts[$0].exists
                },
                2
            )
        }
    }
}


extension MHCTestCase {
    enum RootLevelTab: String, CaseIterable {
        // needs to be kept in sync with the titles in the app
        case home = "Home"
        case upcoming = "Tasks"
        case heartHealth = "Heart Health"
    }
    
    @MainActor
    func goToTab(_ tab: RootLevelTab, timeout: TimeInterval = 2) {
        let button = app.tabBars.buttons["MHC:Tab:\(tab.rawValue)"]
        XCTAssert(button.waitForExistence(timeout: timeout))
        XCTAssert(button.isEnabled)
        XCTAssert(button.isHittable)
        button.tap()
    }
    
    @MainActor
    func openAccountSheet() {
        let button = app.navigationBars.buttons["MHC:YourAccount"]
        XCTAssert(button.waitForExistence(timeout: 1))
        button.tap()
    }
}


extension Locale {
    static let enUS = Locale(identifier: "en_US")
    static let enUK = Locale(identifier: "en_UK")
    static let esUS = Locale(identifier: "es_US")
    static let esES = Locale(identifier: "es_ES")
    static let enDE = Locale(identifier: "en_DE")
}


extension XCUIDevice {
    func pressLockButton() {
        perform(NSSelectorFromString("pressLockButton"))
    }
}


extension XCUIApplication {
    static var springboard: XCUIApplication {
        XCUIApplication(bundleIdentifier: "com.apple.springboard")
    }
    
    /// The url of the iOS application being tested.
    var url: URL? {
        guard let impl = self.value(forKey: "_applicationImpl") as? NSObject else {
            return nil
        }
        guard let path = impl.value(forKey: "_path") as? String else {
            return nil
        }
        return URL(filePath: path)
    }
    
    /// The main bundle of the iOS application being tested.
    ///
    /// - Note: This property only works when the app is being tested in the simulator; it does not work when testing on a physical device.
    var mainBundle: Bundle? {
        url.flatMap(Bundle.init(url:))
    }
}


extension XCUIElementQuery {
    func matching(_ predicateFormat: String, _ args: Any...) -> XCUIElementQuery {
        self.matching(NSPredicate(format: predicateFormat, argumentArray: args))
    }
    
    func element(matching predicateFormat: String, _ args: Any...) -> XCUIElement {
        self.element(matching: NSPredicate(format: predicateFormat, argumentArray: args))
    }
}
