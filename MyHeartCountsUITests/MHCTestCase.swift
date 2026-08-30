//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

// swiftlint:disable implicitly_unwrapped_optional file_types_order type_contents_order identifier_name

import Foundation
import GroveFoundation
import GroveLocalization
import HealthKit
import MHCStudyDefinitionExporter
import MyHeartCountsShared
import XCTest
import XCTestExtensions
import XCTGroveNotifications
import XCTHealthKit

/*
 Ideas for additional tests:
 - [dashboard] exercise mins vs step count (+ auto switch based on what's available!)
 - an onboarding test where we enter invalid values and get to the "you're not eligible" step
 */

/// The base class for all MHC UI tests.
///
/// This class sets up the ``app`` property, and provides the ``launchAppAndEnrollIntoStudy`` function.
/// It does not contain any actual tests itself. All UI test classes should inherit from `MHCTestCase`.
@MainActor
class MHCTestCase: XCTestCase, Sendable {
    enum HandlePermissionPrompts: ExpressibleByBooleanLiteral {
        case yes
        case no
        case auto
        
        @available(*, deprecated)
        init(booleanLiteral value: BooleanLiteralType) {
            self = value ? .yes : .no
        }
    }
    
    static let enableHealthRecords = false // temporarily disabled
    
    nonisolated private static let tempDir = URL.temporaryDirectory.appending(
        component: "edu.stanford.MyHeartCounts.UITests",
        directoryHint: .isDirectory
    )
    
    private var _app: MHCXCUIApplication!
    
    var app: XCUIApplication { _app }
    
    /// The on-disk location of the study bundle, for this specific test run.
    ///
    /// Gets reset after every run, in order to isolate each run's study bundles.
    private(set) var studyBundleUrl: URL!
    private(set) var appLocale: Locale!
    /// How many times the app was launched as part of the test currently being executed.
    /// - Note: Only counts launches via ``launchAppAndEnrollIntoStudy``
    private(set) var launchCounter = 0
    /// Whether there likely is at least one protected resource (notifications, health, etc) that currently
    /// is in an undecided state and might trigger a permission prompt during the next enrolled launch.
    private var likelyHasUndecidedPermissions = true
    private var alreadySuppliedHealthCharacteristics = false
    
    
    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false
        _app = MHCXCUIApplication()
        _app.onLaunch = {
            self.launchCounter += 1
        }
        _app.onPermissionsReset = { _ in
            self.likelyHasUndecidedPermissions = true
        }
        try FileManager.default.createDirectory(at: Self.tempDir, withIntermediateDirectories: true)
        // note that we intentionally export the study bundle as a package (rather than an archive),
        // so that tests can tinker with the contents if they want to.
        // e.g., the consent renewal tests use this to simulate the consent version updating between launches.
        studyBundleUrl = try MHCStudyDefinitionExporter::export(to: Self.tempDir, as: .package)
    }
    
    override func tearDown() async throws {
        try await super.tearDown()
        app.terminate()
        _app = nil
        appLocale = nil
        launchCounter = 0
        try FileManager.default.removeItem(at: studyBundleUrl)
    }
    
    override class func tearDown() {
        super.tearDown()
        try? FileManager.default.removeItem(at: Self.tempDir)
    }
    
    /// Launches the app and puts it in a state where the participant is logged in and enrolled into the study.
    ///
    /// - parameter enableDebugMode: Whether the app should force-enable its debug mode for this launch. Defaults to `false`.
    /// - parameter handlePermissionPrompts: Whether permission prompts for notifications, HealthKit, etc should be waited for and handled as part of launching the app.
    ///     Defaults to `.auto`, in which case the function will intelligently decide if permission prompts are likely to appear as part of the launch, and await and handle them as needed.
    /// - parameter promptedActionsFilter: which prompted actions should be considered for display on the home tab, if any. defaults to not showing any prompted actions.
    /// - parameter heightEntryUnitOverride: Allows overriding the unit the app will use when manually entering a height quantity.
    ///     Allowed values are `cm`, `feet`, or `nil` (the default).
    /// - parameter weightEntryUnitOverride: Allows overriding the unit the app will use when manually entering a weight quantity.
    ///     Allowed values are `kg`, `lbs`, or `nil` (the default).
    /// - parameter extraLaunchArgs: Additional arguments that will be appended to the app's launch arguments. `nil` values will be skipped.
    func launchAppAndEnrollIntoStudy( // swiftlint:disable:this function_body_length
        skip: Bool = false,
        locale: Locale = .enUS,
        enableDebugMode: Bool = false,
        testEnvironmentConfig: SetupTestEnvironmentConfig = .init(resetExistingData: true, loginAndEnroll: .enable(.random())),
        enableHealthRecords: Bool = MHCTestCase.enableHealthRecords,
        handlePermissionPrompts: HandlePermissionPrompts = .auto,
        skipGoingToHomeTab: Bool = false,
        promptedActionsFilter: PromptedActionsFilter = .only([]),
        triggerConsentRenewalIfNeverSigned: Bool = false,
        heightEntryUnitOverride: LaunchOptions.HeightInputUnitOverride = .none,
        weightEntryUnitOverride: LaunchOptions.WeightInputUnitOverride = .none,
        extraLaunchOptions: [any _AnyExtraLaunchOption] = [],
        extraLaunchArgs: [String?] = [],
        extraEnvironmentEntries: [String: String] = [:]
    ) throws {
        if skip {
            throw XCTSkip()
        }
        appLocale = locale
        app.launchArguments = Array {
            "--useFirebaseEmulator"
            testEnvironmentConfig.launchOptionArgs(for: .setupTestEnvironment)
            StudyBundleSelector.atUrl(studyBundleUrl).launchOptionArgs(for: .studyBundleSelector)
            "--disableAutomaticBulkHealthExport"
            enableDebugMode.launchOptionArgs(for: .forceEnableDebugMode)
            enableHealthRecords.launchOptionArgs(for: .enableHealthRecords)
            heightEntryUnitOverride.launchOptionArgs(for: .heightInputUnitOverride)
            weightEntryUnitOverride.launchOptionArgs(for: .weightInputUnitOverride)
            promptedActionsFilter.launchOptionArgs(for: .promptedActionsFilter)
            triggerConsentRenewalIfNeverSigned.launchOptionArgs(for: .triggerConsentRenewalIfNeverSigned)
        }
        app.launchArguments += extraLaunchOptions.flatMap(\.rawArgs)
        app.launchArguments += extraLaunchArgs.compactMap(\.self)
        app.launchArguments += [
            "-AppleLanguages", "(\(locale.language.minimalIdentifier))",
            "-AppleLocale", try XCTUnwrap(LocalizationKey(locale: locale)).description
        ]
        app.launchEnvironment["MHC_IS_BEING_UI_TESTED"] = "1"
        app.launchEnvironment.merge(extraEnvironmentEntries, using: .override)
        print(app.dumpLaunchContext())
        XCTAssertFalse(
            app.launchArguments.contains { $0.contains("'") },
            "XCUIApplication.launchArguments doesn't support single quote chars within launch arguments (see FB23653577)"
        )
        app.launch()
        XCTAssert(app.wait(for: .runningForeground, timeout: 2))
        switch handlePermissionPrompts {
        case .no:
            break
        case .auto:
            let mightRunAccessRequestsOnLaunch = switch testEnvironmentConfig.loginAndEnroll {
            case .skip:
                false
            case .enable:
                true
            }
            if mightRunAccessRequestsOnLaunch && likelyHasUndecidedPermissions {
                fallthrough
            } else {
                break
            }
        case .yes:
            app.confirmNotificationAuthorization()
            app.handleHealthKitAuthorization(timeout: 10) // Idea: maybe adjust this based on local vs CI?
            if MHCTestCase.enableHealthRecords {
                handleHealthRecordsAuthorization(
                    healthRecordTypes: HealthRecordType.allCases,
                    automaticallyShareUpdates: true,
                    timeout: 10
                )
            }
            likelyHasUndecidedPermissions = false
        }
        if !skipGoingToHomeTab && !(testEnvironmentConfig == .init(resetExistingData: true, loginAndEnroll: .skip)) {
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
    
    
    func supplyHealthCharacteristics() throws {
        guard !alreadySuppliedHealthCharacteristics else {
            return
        }
        try launchHealthAppAndEnterCharacteristics(.init(
            bloodType: .aPositive,
            dateOfBirth: .init(year: 1998, month: 6, day: 2),
            biologicalSex: .male,
            skinType: .II,
            wheelchairUse: .no
        ))
        alreadySuppliedHealthCharacteristics = true
    }
}


extension MHCTestCase {
    protocol _AnyExtraLaunchOption { // swiftlint:disable:this type_name
        var rawArgs: [String] { get }
    }
    
    struct LaunchOptionValue<T: LaunchOptionEncodable>: _AnyExtraLaunchOption {
        private let option: LaunchOption<T>
        private let value: T
        
        init(_ value: T, for option: LaunchOption<T>) {
            self.option = option
            self.value = value
        }
        
        var rawArgs: [String] {
            value.launchOptionArgs(for: option)
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
    
    func goToTab(_ tab: RootLevelTab, timeout: TimeInterval = 2) {
        let button = app.tabBars.buttons["MHC:Tab:\(tab.rawValue)"]
        XCTAssert(button.waitForExistence(timeout: timeout))
        XCTAssert(button.isEnabled)
        XCTAssert(button.isHittable)
        button.tap()
        sleep(for: .seconds(0.5))
    }
    
    func openAccountSheet() {
        let button = app.navigationBars.buttons["MHC:YourAccount"]
        XCTAssert(button.waitForExistence(timeout: 1))
        button.tap()
    }
    
    func closeAccountSheet() {
        let sheet = app.otherElements["MHC:AccountSheet"]
        XCTAssert(sheet.waitForExistence(timeout: 2))
        sheet.navigationBars.buttons["Close"].tap()
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
    
    
    func dumpLaunchContext() -> String {
        var msg = "Will launch app \(self.bundleIdentifier) with configuration:\n"
        msg += "argv:\n"
        for arg in self.launchArguments {
            msg += "    \(arg)\n"
        }
        msg += "env:\n"
        for (key, value) in self.launchEnvironment {
            msg += "    \(key) = \(value)\n"
        }
        return msg
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


// MARK: XCUIApplication

private final class MHCXCUIApplication: XCUIApplication {
    var onLaunch: (() -> Void)?
    var onPermissionsReset: ((_ resource: XCUIProtectedResource) -> Void)?
    
    override func launch() {
        super.launch()
        onLaunch?()
    }
    
    override func resetAuthorizationStatus(for resource: XCUIProtectedResource) {
        super.resetAuthorizationStatus(for: resource)
        onPermissionsReset?(resource)
    }
}
