//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import SpeziHealthKitFHIR
import MyHeartCountsShared
import OSLog
import Spezi
import SpeziAccount
import SpeziFirebaseAccount
import SpeziFoundation
import SpeziHealthKit
import SpeziHealthKitBulkExport
import SpeziLocalStorage
import SpeziStudy
import struct SpeziViews.AnyLocalizedError


/// Sets up a test environment, by logging into a test account and enrolling in the current study definition.
@Observable
@MainActor
final class SetupTestEnvironment: Module, EnvironmentAccessible, Sendable {
    typealias Config = SetupTestEnvironmentConfig
    enum State {
        /// The test environment hasn't been set up, and will not be set up.
        case disabled
        /// The test environment will soon be set up.
        case pending
        /// The test environment is currently being set up
        case settingUp
        /// The test environment has been set up
        case done
        /// There was an error setting up the test environment
        case failure(any Error)
    }
    
    // swiftlint:disable attributes
    @ObservationIgnored @Application(\.logger) private var logger
    @ObservationIgnored @StandardActor private var standard: MyHeartCountsStandard
    @ObservationIgnored @Dependency(FirebaseAccountService.self) private var accountService: FirebaseAccountService?
    @ObservationIgnored @Dependency(StudyBundleLoader.self) private var studyBundleLoader
    @ObservationIgnored @Dependency(HealthKit.self) private var healthKit
    @ObservationIgnored @Dependency(ClinicalRecordPermissions.self) private var clinicalRecordPermissions
    @ObservationIgnored @Dependency(BulkHealthExporter.self) private var bulkHealthExporter
    @ObservationIgnored @Dependency(ManagedFileUpload.self) private var fileUploader
    @ObservationIgnored @Dependency(LocalStorage.self) private var localStorage
    @ObservationIgnored @Dependency(StudyManager.self) private var studyManager: StudyManager?
    // swiftlint:enable attributes
    
    @ObservationIgnored private let config: Config = LaunchOptions.launchOptions[.setupTestEnvironment]
    @MainActor private(set) var isInSetup = false
    
    private(set) var state: State
    private(set) var desc = ""
    
    init() {
        state = if FeatureFlags.disableFirebase || config == .disabled {
            .disabled
        } else {
            .pending
        }
    }
    
    func configure() {
        switch state {
        case .pending:
            Task { @MainActor in
                self.state = .settingUp
                if !Spezi.didLoadFirebase {
                    Spezi.loadFirebase(for: .unitedStates)
                    try? await _Concurrency.Task.sleep(for: .seconds(4))
                }
                do {
                    try await setUp()
                    logger.notice("Successfully set up test environment")
                    self.state = .done
                } catch {
                    logger.error("ERROR SETTING UP TEST ENVIRONMENT: \(error)")
                    self.state = .failure(AnyLocalizedError(error: error, defaultErrorDescription: "\(error)"))
                }
            }
        default:
            break
        }
    }
    
    private func setUp() async throws {
        isInSetup = true
        defer {
            isInSetup = false
        }
        if config.resetExistingData {
            desc = "\(#function) will reset existing data"
            try await resetExistingData()
        }
        if config.loginAndEnroll {
            desc = "\(#function) will loginAndEnroll"
            try await loginAndEnroll()
        }
    }
    
    
    private func resetExistingData() async throws {
        logger.notice("Resetting existing data")
        try localStorage.deleteAll()
        try await bulkHealthExporter.deleteSessionRestorationInfo(for: .mhcHistoricalDataExport)
        try fileUploader.clearPendingUploads()
        if let studyManager {
            for enrollment in studyManager.studyEnrollments {
                try await studyManager.unenroll(from: enrollment)
            }
        }
        if let accountService {
            do {
                try await accountService.logout()
            } catch FirebaseAccountError.notSignedIn {
                // ok
            }
        }
    }
    
    
    private func loginAndEnroll() async throws {
        logger.notice("Logging in and enrolling into Study")
        guard let accountService else {
            logger.error("Unable to log in and enroll: no AccountService!")
            return
        }
        guard studyManager != nil else {
            logger.error("Unable to log in and enroll: no StudyManager!")
            return
        }
        do {
            try await accountService.login(userId: "leland@stanford.edu", password: "StanfordRocks!")
        } catch FirebaseAccountError.invalidCredentials {
            // account doesn't exist yet, signup
            var details = AccountDetails()
            details.userId = "leland@stanford.edu"
            details.password = "StanfordRocks!"
            details.name = PersonNameComponents(givenName: "Leland", familyName: "Stanford")
            details.genderIdentity = .male
            do {
                try await accountService.signUp(with: details)
            } catch {
                logger.error("Failed to setup test account: \(error)")
                throw error
            }
        } catch {
            // an error occurred logging in to the test account, and it's not because the account doesn't exist.
            throw error
        }
        desc = "\(#function) will update study bundle loader"
        // this is important, bc if we're developing locally the study bundle might've been updated since the last time the app was launched.
        let studyBundle = try await studyBundleLoader.update()
        logger.notice("Enrolling test environment into study bundle")
        let accessReqs = MyHeartCountsStandard.baselineHealthAccessReqs.merging(
            with: .init(read: studyBundle.studyDefinition.allCollectedHealthData(includingOptionalSampleTypes: true).exceptClinicalRecordTypes())
        )
        desc = "\(#function) will ask for regular HK auth"
        try await healthKit.askForAuthorization(for: accessReqs)
        desc = "\(#function) will enroll"
        try await standard.enroll(in: studyBundle)
        if ClinicalRecordPermissions.isAvailable {
            desc = "\(#function) will ask for clinical access"
            try await _Concurrency.Task.sleep(for: .seconds(1))
            try await clinicalRecordPermissions.askForAuthorization(askAgainIfCancelledPreviously: false)
        }
        LocalPreferencesStore.standard[.onboardingFlowComplete] = true
        desc = "\(#function) DONE"
    }
}


extension SampleTypesCollection {
    func onlyClinicalRecordTypes() -> Self {
        filter(isKindOf: SampleType<HKClinicalRecord>.self)
    }
    
    func exceptClinicalRecordTypes() -> Self {
        filter(isNotKindOf: SampleType<HKClinicalRecord>.self)
    }
    
    func filter<Sample>(isKindOf _: SampleType<Sample>.Type) -> Self {
        Self(self.filter { $0 is SampleType<Sample> })
    }
    
    func filter<Sample>(isNotKindOf _: SampleType<Sample>.Type) -> Self {
        Self(self.filter { !($0 is SampleType<Sample>) })
    }
}
