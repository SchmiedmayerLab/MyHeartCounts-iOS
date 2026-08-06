//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import HealthKitOnFHIR
import MyHeartCountsShared
import OSLog
import Spezi
import SpeziAccount
import SpeziConsent
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
    @ObservationIgnored @Dependency(Account.self) private var account: Account?
    @ObservationIgnored @Dependency(FirebaseAccountService.self) private var accountService: FirebaseAccountService?
    @ObservationIgnored @Dependency(StudyBundleLoader.self) private var studyBundleLoader
    @ObservationIgnored @Dependency(HealthKit.self) private var healthKit
    @ObservationIgnored @Dependency(ClinicalRecordPermissions.self) private var clinicalRecordPermissions
    @ObservationIgnored @Dependency(BulkHealthExporter.self) private var bulkHealthExporter
    @ObservationIgnored @Dependency(ManagedFileUpload.self) private var fileUploader
    @ObservationIgnored @Dependency(LocalStorage.self) private var localStorage
    @ObservationIgnored @Dependency(ConsentManager.self) private var consentManager: ConsentManager?
    @ObservationIgnored @Dependency(StudyManager.self) private var studyManager: StudyManager?
    // swiftlint:enable attributes
    
    @ObservationIgnored private let config: Config = LaunchOptions.launchOptions[.setupTestEnvironment]
    @MainActor private(set) var isInSetup = false
    
    private(set) var state: State
    private(set) var desc = "" {
        didSet {
            let desc = desc
            logger.notice("\(desc)")
        }
    }
    
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
                    try? await _Concurrency.Task.sleep(for: .seconds(1))
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
            Task {
                // It's important that this runs after isInSetup is cleared;
                // otherwise eg the ConsentManager will see the new study bundle and run its renewal flow logic,
                // but return early bc it sees that the test env setup is still ongoing.
                // Run a bundle update, this will end up re-fetching the exact same bundle we already fetched above,
                // but it'll also trigger all components in the app that observe the study bundle.
                // (eg the ConsentManager, for the renewal flow.)
                _ = try? await self.studyBundleLoader.update()
            }
        }
        if config.resetExistingData {
            desc = "\(#function) will reset existing data"
            try await resetExistingData()
        }
        switch config.loginAndEnroll {
        case .skip:
            break
        case .enable(let credentials):
            desc = "\(#function) will loginAndEnroll"
            try await loginAndEnroll(credentials)
        }
    }
    
    
    private func resetExistingData() async throws {
        logger.notice("Resetting existing data")
        try await bulkHealthExporter.deleteSessionRestorationInfo(for: .mhcHistoricalDataExport)
        try await fileUploader.clearPendingUploads()
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
        LocalPreferencesStore.standard.removeAllEntries(in: .app)
        switch config.loginAndEnroll {
        case .skip:
            break
        case .enable:
            // we set this here already to prevent the onboarding sheet from popping up
            LocalPreferencesStore.standard[.onboardingFlowComplete] = true
        }
        try await Task.sleep(for: .seconds(0.5))
        do {
            try localStorage.deleteAll()
        } catch {
            try await Task.sleep(for: .seconds(2))
            try localStorage.deleteAll()
        }
    }
    
    
    private func loginAndEnroll( // swiftlint:disable:this function_body_length cyclomatic_complexity
        _ credentials: SetupTestEnvironmentConfig.Credentials
    ) async throws {
        logger.notice("Logging in and enrolling into Study using credentials \(String(describing: credentials))")
        // we set this immediately at the beginning, since the value will likely have been cleared in
        // the `resetExistingData()` call preceding this `loginAndEnroll()` call, and we don't want the
        // onboarding sheet covering the "Setting up Test Environment" full-screen thing.
        LocalPreferencesStore.standard[.onboardingFlowComplete] = true
        guard let accountService, let account, let consentManager else {
            logger.error("Unable to log in and enroll: missing dependencies!")
            return
        }
        guard studyManager != nil else {
            logger.error("Unable to log in and enroll: no StudyManager!")
            return
        }
        do {
            // FirebaseAccountService's `login(userId:password:)` will unconditionally log the user out,
            // even if it is the same user the function is asked to log in to.
            // we need to prevent this, since the logout would trigger all of the local data to get reset,
            // which might be at odds with our config here.
            if !account.signedIn || account.details?.userId != credentials.username {
                logger.notice("account.signedIn? \(account.signedIn); account.userId: \(account.details?.userId ?? "n/a")")
                try await accountService.login(userId: credentials.username, password: credentials.password)
            }
        } catch FirebaseAccountError.invalidCredentials {
            // account doesn't exist yet, signup
            var details = AccountDetails()
            details.userId = credentials.username
            details.password = credentials.password
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
        
        // fill in all account details we'd normally have provided via the onboarding flow
        do {
            var newDetails = AccountDetails()
            // consent
            if let newVersion = LaunchOptions[.overrideLastSignedConsentVersion] {
                newDetails.lastSignedConsentVersion = newVersion.description
            } else if let details = account.details,
                      details.lastSignedConsentVersion == nil,
                      let consentDoc = try? consentManager.loadConsentDoc(from: studyBundle),
                      let consentVersion = consentDoc.metadata.version {
                // unless already present, we set the account's `lastSignedConsentVersion`; this otherwise would happen as part of the regular onboarding {
                newDetails.lastSignedConsentVersion = consentVersion.description
                newDetails.lastSignedConsentDate = Date()
            }
            newDetails.didOptInToTrial = true
            // demographics
            if LaunchOptions[.supplyDemographicsWhenCreatingTestAccount] {
                newDetails.dateOfBirth = Calendar.current.date(
                    from: .init(timeZone: TimeZone(identifier: "America/New_York"), year: 1824, month: 3, day: 9)
                )
                newDetails.mhcGenderIdentity = .male
                newDetails.biologicalSexAtBirth = .male
                newDetails.bloodType = .aPositive
                newDetails.heightInCM = 186
                newDetails.weightInKG = 67
                newDetails.raceEthnicity = .white
                newDetails.latinoStatus = LatinoStatusOption.options[0]
                newDetails.comorbidities = { () -> Comorbidities in
                    var value = Comorbidities()
                    guard let heartFailureOption = Comorbidities.Comorbidity.primaryComorbidities.first(where: {
                        $0.title.localizedString(for: .enUS).contains("Heart Failure")
                    }) else {
                        return value
                    }
                    value[heartFailureOption] = .selected(startDate: DateComponents())
                    return value
                }()
                newDetails.usRegion = .dc
                newDetails.householdIncomeUS = HouseholdIncomeUS.options[0]
                newDetails.educationUS = EducationStatusUS.options[0]
                newDetails.stageOfChange = StageOfChangeOption.allOptions[0]
                newDetails.referralSource = ReferralSource.options[0]
            }
            // activity prefs
            newDetails.preferredWorkoutTypes = .init([WorkoutPreferenceSetting.WorkoutType.options[0]])
            newDetails.preferredNudgeNotificationTime = .init(hour: 9, minute: 0)
            // finalize
            let modifications = try AccountModifications(modifiedDetails: newDetails)
            try await accountService.updateAccountDetails(modifications)
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
