//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
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
            ManagedFileUpload {
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
}


extension ModuleBuilder {
    // periphery:ignore - implicitly called
    static func buildExpression(_ modules: some Sequence<any Module>) -> [any Module] {
        Array(modules)
    }
}


extension ProcessInfo {
    static var isReallyRunningInXCTest: Bool {
        Self.isRunningInXCTest && Self.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}
