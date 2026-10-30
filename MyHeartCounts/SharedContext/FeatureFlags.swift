//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2023 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFoundation
import MHCStudyDefinition
import MyHeartCountsShared


/// A collection of feature flags for My Heart Counts.
enum FeatureFlags {
    /// Selects the variant for fresh test enrollments, including bundles loaded from a URL.
    static var studyVariantOverride: StudyVariant? {
        #if DEBUG
        LaunchOptions.launchOptions[.studyVariant]
        #else
        nil
        #endif
    }

    /// Unlocks temporary Imperial enrollment against the US backend in Debug builds, the simulator, and TestFlight installations.
    /// Enter `pls let me in anyway` in the UK Coming Soon screen's email field to enter this mode.
    /// Existing enrollments retain their saved study variant and backend independently of this flag.
    static var enableUKStudyTesting: Bool {
        #if DEBUG || targetEnvironment(simulator)
        true
        #else
        Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
        #endif
    }

    /// Disables the Firebase interactions, including the login/sign-up step and the Firebase Firestore upload.
    ///
    /// - Note: This takes precedence over all other firebase-related flags.
    ///
    /// - Important: This option will make the app basically unusable and exists solely for the purpose of allowing the unit tests to run without crashing.
    ///     It should not be used for anything else.
    static var disableFirebase: Bool {
        LaunchOptions.launchOptions[.disableFirebase]
    }
    
    /// Defines if the application should connect to the local firebase emulator.
    static var useFirebaseEmulator: Bool {
        LaunchOptions.launchOptions[.useFirebaseEmulator] || LaunchOptions.launchOptions[.setupTestEnvironment] != .disabled
    }
    
    /// Disables the automatic bulk export and upload of historical Health data
    static var disableAutomaticBulkHealthExport: Bool {
        LaunchOptions.launchOptions[.disableAutomaticBulkHealthExport]
    }
    
    /// Whether the should load a special, different Firebase config instead of the one that would regularly get loaded.
    ///
    /// If specified, the ``DeferredConfigLoading`` module will unconditionally attempt to load the override config.
    static var overrideFirebaseConfig: DeferredConfigLoading.FirebaseConfigSelector? {
        LaunchOptions.launchOptions[.overrideFirebaseConfig]
    }
    
    /// Whether Health-Record-related functionality should be enabled.
    static var enableHealthRecords: Bool {
        LaunchOptions.launchOptions[.enableHealthRecords]
    }
}


extension LaunchOptions {
    static let disableFirebase = LaunchOption<Bool>("--disableFirebase", default: false)
    static let useFirebaseEmulator = LaunchOption<Bool>("--useFirebaseEmulator", default: false)
    static let overrideFirebaseConfig = LaunchOption<DeferredConfigLoading.FirebaseConfigSelector?>("--overrideFirebaseConfig", default: nil)
    
    static let disableAutomaticBulkHealthExport = LaunchOption<Bool>("--disableAutomaticBulkHealthExport", default: false)
    
    static let disableSensorKitUpload = LaunchOption<Bool>("--disableSensorKitUpload", default: false)
}
