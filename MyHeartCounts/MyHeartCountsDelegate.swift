//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Grove
import GroveFirebaseConfiguration
import GroveFoundation
import GroveHealthKit
import GroveHealthKitBulkExport
import GroveNotifications
import GroveOnboarding
import GroveScheduler
import GroveSensorKit
import GroveStudy
import OSLog
import SwiftUI
import UserNotifications


@Observable
final class MyHeartCountsDelegate: GroveAppDelegate {
    /// Whether the app is able to display its regular UI.
    enum LaunchState {
        /// Nothing is keeping the app from displaying its regular UI.
        case ready
        /// The test environment is currently being set up.
        case settingUpTestEnvironment(description: String)
        /// The app failed to launch, and can't display its regular UI.
        case failed(any Error)
    }

    // mutated only once, from the main actor, when the app's launch sequence is finishing up.
    nonisolated(unsafe) private(set) static var didFinishLaunching = false

    private let setupTestEnvironment = SetupTestEnvironment()
    /// The error that kept the app from loading its Firebase config during launch, if any.
    private var launchError: (any Error)?

    var launchState: LaunchState {
        if let launchError {
            return .failed(launchError)
        }
        return switch setupTestEnvironment.state {
        case .disabled, .done:
            .ready
        case .pending, .settingUp:
            .settingUpTestEnvironment(description: setupTestEnvironment.desc)
        case .failure(let error):
            .failed(error)
        }
    }

    override var configuration: Configuration {
        Configuration(standard: MyHeartCountsStandard()) { // swiftlint:disable:this closure_body_length
            FirebaseConfiguration()
            setupTestEnvironment
            loadInitialConfig()
            HealthKit()
            FHIRExchangeLedger(
                location: ProcessInfo.isReallyRunningInXCTest ? .inMemory : .default
            )
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
            ParticipationStatsProvider()
            AchievementsManager()
        }
    }
    
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? // swiftlint:disable:this discouraged_optional_collection
    ) -> Bool {
        Self.didFinishLaunching = true
        return true
    }

    private func loadInitialConfig() -> [any Module] {
        do throws(DeferredConfigLoading.LoadingError) {
            return try DeferredConfigLoading.initialAppLaunchConfig()
        } catch {
            logger.error("Unable to load the Firebase config during launch: \(error)")
            launchError = error
            return []
        }
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
