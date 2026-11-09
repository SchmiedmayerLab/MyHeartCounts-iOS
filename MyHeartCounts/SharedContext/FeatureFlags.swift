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
    /// Unlocks temporary Imperial enrollment against the US backend in Debug builds, the simulator, and TestFlight installations.
    /// Enter `pls let me in anyway` in the UK Coming Soon screen's email field to enter this mode.
    /// Existing enrollments retain their saved study variant and backend independently of this flag.
    static var enableUKStudyTesting: Bool {
        isDevelopmentOrTestFlightBuild
    }

    /// Whether this is a Debug build, a simulator build, or a TestFlight installation, as opposed to an App Store installation.
    static var isDevelopmentOrTestFlightBuild: Bool {
        #if DEBUG || targetEnvironment(simulator)
        true
        #else
        Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
        #endif
    }

    /// Forces the entire app to unconditionally use a specific study variant.
    ///
    /// The value here is determined based on the first match from the following sources:
    /// 1. Info.plist entry for the `MHCForcedStudyVariant` key
    /// 2. `--studyVariant` launch option
    ///
    /// All aspects of the app should follow this value, e.g. the onboarding will be locked to a single study variant
    /// (the region selection is fixed to the variant's region, which then is eligible for enrollment).
    /// These builds also use the study bundle they were built with, instead of the one published to the backend.
    ///
    /// A `nil` value means that no variant is being forced, and the app will determine the current/active variant normally,
    /// e.g. based on the last launch's active variant.
    static var forcedStudyVariant: StudyVariant? {
        if let rawValue = Bundle.main.object(forInfoDictionaryKey: "MHCForcedStudyVariant") as? String {
            guard let variant = StudyVariant(rawValue: rawValue) else {
                preconditionFailure("Info.plist 'MHCForcedStudyVariant' key has invalid value '\(rawValue)'")
            }
            return variant
        }
        return LaunchOptions.launchOptions[.studyVariant]
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

    /// Whether the HealthKit exporter measures its throughput, logged after each export batch; for local profiling.
    static var measureExporterThroughput: Bool {
        LaunchOptions.launchOptions[.measureExporterThroughput]
    }

    /// Whether every HealthKit batch export is recorded in ``HealthKitExportLog``, with the exporter's throughput; for
    /// analysing test runs off the device.
    static var recordHealthKitExportLog: Bool {
        LaunchOptions.launchOptions[.recordHealthKitExportLog]
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
    static let measureExporterThroughput = LaunchOption<Bool>("--measureExporterThroughput", default: false)
    static let recordHealthKitExportLog = LaunchOption<Bool>("--recordHealthKitExportLog", default: false)
    
    static let disableSensorKitUpload = LaunchOption<Bool>("--disableSensorKitUpload", default: false)
    /// The minimum time, in seconds, between two SensorKit fetches started by app launches; `0` fetches on every launch.
    static let sensorKitMinimumFetchInterval = LaunchOption<TimeInterval>("--sensorKitMinimumFetchInterval", default: 12 * TimeConstants.hour)
    /// Stages every file upload as usual, but never performs any of them; for measuring how much a workload stages.
    static let disableFileUploads = LaunchOption<Bool>("--disableFileUploads", default: false)
}
