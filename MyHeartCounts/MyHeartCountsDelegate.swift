//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import OSLog
import Spezi
import SpeziFirebaseConfiguration
import SpeziFoundation
import SpeziHealthKit
import SpeziHealthKitBulkExport
import SpeziNotifications
import SpeziOnboarding
import SpeziScheduler
import SpeziSensorKit
import SpeziStudy
import SwiftUI
import UserNotifications


@Observable
final class MyHeartCountsDelegate: SpeziAppDelegate {
    // mutated only once, from the main actor, when the app's launch sequence is finishing up.
    nonisolated(unsafe) private(set) static var didFinishLaunching = false
    
    override var configuration: Configuration {
        if let selector = FeatureFlags.overrideFirebaseConfig {
            LocalPreferencesStore.standard[.lastUsedFirebaseConfig] = selector
        }
        return Configuration(standard: MyHeartCountsStandard()) { // swiftlint:disable:this closure_body_length
            FirebaseConfiguration()
            SetupTestEnvironment()
            DeferredConfigLoading.initialAppLaunchConfig
            HealthKit()
            HealthUploadStaging(
                persistence: ProcessInfo.isReallyRunningInXCTest ? .inMemory : .onDisk
            )
            HealthUploadStagingUploader()
            ClinicalRecordPermissions()
            Scheduler(
                persistence: ProcessInfo.isReallyRunningInXCTest ? .inMemory : .onDisk
            )
            Notifications()
            BulkHealthExporter()
            HistoricalHealthSamplesExportManager()
            StudyBundleLoader.shared
            WatchConnection()
            TimedWalkingTest()
            FeedbackManager()
            SensorKit()
            SensorKitDataFetcher()
            LocalNotifications()
            Lifecycle()
            AppState()
            AppRefresh()
            MHCBackgroundTasks()
            ManagedFileUpload(
                configuration: .init(isStoredInMemoryOnly: ProcessInfo.isReallyRunningInXCTest)
            ) {
                ManagedFileUpload.Category.liveHealthUpload
                ManagedFileUpload.Category.historicalHealthUpload
                ManagedFileUpload.Category.healthDeletions
                for sensor in SensorKit.mhcSensors {
                    ManagedFileUpload.Category(sensor)
                }
            }
            NotificationTracking()
            NotificationsManager()
            AccountFeatureFlags()
            DemoSetup()
        }
    }
    
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? // swiftlint:disable:this discouraged_optional_collection
    ) -> Bool {
        Self.didFinishLaunching = true
        return true
    }
}


extension ModuleBuilder {
    static func buildExpression(_ modules: some Sequence<any Module>) -> [any Module] {
        Array(modules)
    }
}


extension ProcessInfo {
    static var isReallyRunningInXCTest: Bool {
        Self.isRunningInXCTest && Self.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}
