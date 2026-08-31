//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

@preconcurrency import FirebaseAuth
@preconcurrency import FirebaseCore
@preconcurrency import FirebaseFirestore
@preconcurrency import FirebaseStorage
import Grove
import GroveAccount
import GroveFirebaseAccount
import GroveFirestore
import GroveFoundation
import GroveHealthKit
import GroveLocalStorage
import GroveNotifications
import GroveScheduler
import GroveSensorKit
import GroveStudy
import OSLog
@preconcurrency import PDFKit.PDFDocument
import SwiftUI


actor MyHeartCountsStandard: Standard, EnvironmentAccessible, AccountNotifyConstraint {
    // swiftlint:disable attributes
    @Application(\.grove) var grove
    @Application(\.logger) var logger
    @Dependency(HealthKit.self) var healthKit
    @Dependency(FirebaseConfiguration.self) var firebaseConfiguration
    @Dependency(StudyManager.self) var studyManager: StudyManager?
    @Dependency(Account.self) var account: Account?
    @Dependency(LocalStorage.self) private var localStorage
    @Dependency(StudyBundleLoader.self) private var studyLoader
    @Dependency(EnvironmentTracking.self) private var environmentTracking: EnvironmentTracking?
    @Dependency(ManagedFileUpload.self) var managedFileUpload
    @Dependency(SetupTestEnvironment.self) private var setupTestEnvironment
    @Dependency(HistoricalHealthSamplesExportManager.self) private var historicalUploadManager
    @Dependency(NotificationTracking.self) var notificationTracking
    @Dependency(Scheduler.self) var scheduler
    @Dependency(SensorKitDataFetcher.self) private var sensorKitFetcher
    @Dependency(HealthUploadStaging.self) var healthUploadStaging
    @Dependency(HealthUploadStagingUploader.self) private var healthUploadStagingUploader
    @Dependency(ClinicalRecordPermissions.self) private var clinicalRecordPermissions
    @Dependency(NotificationsManager.self) private var notificationsManager
    @Dependency(AppState.self) private var appState
    @Application(\.registerRemoteNotifications) private var registerRemoteNotifications
    // swiftlint:disable attributes

    init() {}

    /// The encrypted, installation-scoped ledger shared by every FHIR publication path.
    func fhirExchangeStateStore(accountDataGeneration: Int) -> FHIRExchangeStateStore {
        FHIRExchangeStateStore(
            localStorage: localStorage,
            accountDataGeneration: accountDataGeneration
        )
    }
    
    @MainActor
    func configure() {
        _Concurrency.Task {
            await handleIsLoggedOut()
            await handleStudyBundleUpdates()
        }
    }
    
    @MainActor
    private func handleIsLoggedOut() async {
        guard !FeatureFlags.disableFirebase, FirebaseApp.app() != nil else {
            return
        }
        let isLoggedIn1 = Auth.auth().currentUser != nil
        let isLoggedIn2 = await account?.signedIn ?? false
        if !isLoggedIn1 && !isLoggedIn2 {
            // both firebase and GroveAccount tell us that there currently is no logged-in user.
            do {
                try await performLogoutCleanup(context: .onLaunchCleanupBcNoUser)
            } catch {
                await logger.error("\(#function): \(error)")
            }
        }
    }
    
    func enroll(in studyBundle: StudyBundle) async throws {
        guard let account, let studyManager else {
            throw NSError(domain: "edu.stanford.MyHeartCounts", code: 0, userInfo: [
                NSLocalizedDescriptionKey: "Missing Account / StudyManager"
            ])
        }
        do {
            if let enrollmentDate = await account.details?.dateOfEnrollment {
                // the user already has enrolled at some point in the past.
                // we now explicitly specify this enrollment date, to make sure the StudyManager
                // can schedule all study components relative to that.
                try await studyManager.enroll(in: studyBundle, enrollmentDate: enrollmentDate)
            } else {
                let enrollmentDate = Date.now
                try await studyManager.enroll(in: studyBundle, enrollmentDate: enrollmentDate)
                do {
                    var newDetails = AccountDetails()
                    newDetails.dateOfEnrollment = enrollmentDate
                    let modifications = try AccountModifications(modifiedDetails: newDetails)
                    try await account.accountService.updateAccountDetails(modifications)
                }
            }
            LocalPreferencesStore.standard[.studyActivationDate] = .now
            _Concurrency.Task(priority: .background) {
                historicalUploadManager.startAutomaticExportingIfNeeded()
            }
            await Self._updateCurrentEnrollmentInfo(studyManager)
        } catch StudyManager.StudyEnrollmentError.alreadyEnrolledInNewerStudyRevision {
            // should be unreachable, but we'll handle this as a non-error just to be safe.
        } catch {
            throw error
        }
    }
    
    // MARK: Account Stuff
    
    func handleAccountEvent(_ event: AccountNotifications.Event) async {
        let logger = logger
        switch event {
        case .didAssociate(let details):
            logger.notice("account was associated (account id: \(details.accountId))")
            if LocalPreferencesStore.standard[.pendingAccountDataCleanupRequired] {
                do {
                    try await clearPendingAccountData()
                } catch {
                    logger.error("Unable to finish cleanup from the previous account: \(error)")
                    return
                }
            }
            await managedFileUpload.resumePendingUploads()
            _Concurrency.Task {
                await environmentTracking?.triggerAll()
                _ = try? await registerRemoteNotifications()
            }
        case .willDelete:
            logger.notice("account is being deleted")
        case .didDisassociate:
            logger.notice("account did disassociate")
            do {
                try await performLogoutCleanup(context: .explicitUserLogoutEvent)
            } catch {
                logger.error("Unable to clear all local account data during logout: \(error)")
            }
        case .willLogOut:
            logger.notice("account is being logged out")
            LocalPreferencesStore.standard[.pendingAccountDataCleanupRequired] = true
            LocalPreferencesStore.standard[.accountDataGeneration] += 1
            try? await notificationsManager.setFCMToken(nil)
        case .detailsChanged:
            break
        }
    }
}


extension MyHeartCountsStandard {
    func updateStudyDefinition() async {
        // if this ends up updating the StudyBundle, it will trigger the observation tracking in the function below
        _ = try? await studyLoader.update()
    }
    
    private func handleStudyBundleUpdates() async {
        let studyBundle = withObservationTracking {
            studyLoader.studyBundle?.value
        } onChange: { [weak self] in
            Swift::Task { [weak self] in
                await self?.handleStudyBundleUpdates()
            }
        }
        guard let studyManager else {
            return
        }
        defer {
            // we still want this to happen if the study bundle loading below failed
            _Concurrency.Task {
                await Self._updateCurrentEnrollmentInfo(studyManager)
            }
        }
        guard let studyBundle else {
            return
        }
        do {
            logger.notice("Informing StudyManager about v\(studyBundle.studyDefinition.studyRevision) of MHC studyBundle")
            try await studyManager.informAboutStudies([studyBundle])
        } catch {
            logger.error("Error informing StudyManager about study bundle: \(error)")
        }
    }
}


extension MyHeartCountsStandard {
    private enum PendingAccountDataCleanupError: Error {
        case failed
    }

    private enum LogoutCleanupContext {
        /// The cleanup is triggered as part of the app's internal on-launch cleanup handling, bc the app noticed that no user is logged in.
        case onLaunchCleanupBcNoUser
        /// The cleanup is triggered in response to an explicit user logout which just happened.
        case explicitUserLogoutEvent
    }
    
    
    @MainActor
    private func performLogoutCleanup(context: LogoutCleanupContext) async throws {
        await logger.notice("performing logout cleanup")
        // bump the generation here as well (not just in willLogOut): account deletion and SDK-forced sign-outs
        // never go through willLogOut, and an in-flight upload task holding the old generation must not be able
        // to write into the freshly cleared staging state once the cleanup below completes.
        // (flag first, then bump: a concurrent reader that snapshots the new generation must never see the flag still unset.)
        LocalPreferencesStore.standard[.pendingAccountDataCleanupRequired] = true
        LocalPreferencesStore.standard[.accountDataGeneration] += 1
        switch context {
        case .explicitUserLogoutEvent:
            await appState.setIsLoggingOut(true)
        case .onLaunchCleanupBcNoUser:
            break
        }
        // upon logging out, we want to throw the user back to the onboarding.
        // note that the onboarding flow, in this context, won't work 100% identical to when you've just launched the app in a non-logged-in state,
        // since the Firebase SDK and all related Grove modules will still be loaded.
        // we could look into using the `FirebaseApp.deleteApp(_:)` API in combination with attempting to unload the related Grove modules, but that
        // would be anything but trivial.
        // if the user wants to switch to a different region, the easiest approach currently is to just kill and relaunch the app.
        var cleanupFailed = false
        do {
            try await clearPendingAccountData()
        } catch {
            cleanupFailed = true
            await logger.error("Local account-data cleanup remains pending: \(error)")
        }
        await resetLocalStudyState()
        switch context {
        case .explicitUserLogoutEvent:
            await finishExplicitLogout()
        case .onLaunchCleanupBcNoUser:
            break
        }
        guard !cleanupFailed else {
            throw PendingAccountDataCleanupError.failed
        }
    }

    @MainActor
    private func resetLocalStudyState() async {
        LocalPreferencesStore.standard[.rejectedHomeTabPromptedActions] = nil
        LocalPreferencesStore.standard[.studyActivationDate] = nil
        let studyManager = await studyManager
        _ = await _Concurrency.Task { @MainActor in
            guard let studyManager else {
                return
            }
            // there should only ever be one enrollment (the MHC one)
            for enrollment in studyManager.studyEnrollments {
                do {
                    await logger.notice("unenrolling from study.")
                    try await studyManager.unenroll(from: enrollment)
                } catch {
                    await logger.error("Error unenrolling from study: \(error)")
                }
            }
        }.result
    }

    @MainActor
    private func finishExplicitLogout() async {
        // Schedule a firestore persistence cleanup for the nect launch.
        // Ideally we'd have this run immediately, but it only works directly after firebase was loaded.
        LocalPreferencesStore.standard[.shouldClearFirestoreCacheOnNextLaunch] = true
        _Concurrency.Task {
            // it seems that the fact that the account sheet typically is still presented while logging out causes issues with us setting the
            // `onboardingFlowComplete` UserDefaults key being set to true (likely bc the other sheet still being presented prevents SwiftUI from presenting the
            // onboarding sheet, thereby causing it to set the UserDefaults key (which, via a Binding, is used as the onboarding sheet's `isPresented` value)
            // back to false.
            // We try to work around this by waiting a bit, to give the account sheet a chance to dismiss itself.
            try await _Concurrency.Task.sleep(for: .seconds(2))
            // NOTE: the guard is evaluated *after* the sleep, deliberately. A logout triggered at launch (from a
            // keychain-restored Firebase session) resolves `isInSetup == false`, because SetupTestEnvironment
            // hasn't entered `setUp()` yet -- it is still behind `Grove.loadFirebase` + its 1s sleep. Snapshotting
            // the guard before the sleep therefore let this task clobber `onboardingFlowComplete` two seconds
            // later, potentially in the middle of the reset's own login-and-enroll. Re-reading it here, and
            // bailing if somebody signed in during the window, keeps that from happening.
            let isInTestEnvSetup = await setupTestEnvironment.isInSetup
            let isSignedIn = (await account?.signedIn) ?? false
            guard /*!ProcessInfo.isBeingUITested,*/ !isInTestEnvSetup, !isSignedIn else {
                // ^we potentially log out and in as part of the test env setup; we want to skip this
                await appState.setIsLoggingOut(false)
                return
            }
            await logger.notice("Triggering Onboarding Flow")
            LocalPreferencesStore.standard[.onboardingFlowComplete] = false
            await appState.setIsLoggingOut(false)
        }
    }

    private func clearPendingAccountData() async throws {
        await healthUploadStagingUploader.cancelAndWaitForQuiescence()
        await sensorKitFetcher.cancelAllActiveCollection()

        func attempt(_ name: String, _ operation: () async throws -> Void) async -> Bool {
            do {
                try await operation()
                return true
            } catch {
                self.logger.error("Unable to clear \(name): \(error)")
                return false
            }
        }
        let historicalDataCleared = await attempt("historical HealthKit export state") {
            try await historicalUploadManager.fullyResetSession(restart: false, clearPendingUploads: false)
        }
        let stagedFilesCleared = await attempt("staged upload files") {
            try await managedFileUpload.clearPendingUploads()
        }
        let stagedHealthDataCleared = await attempt("staged health observations") {
            try healthUploadStaging.clear()
        }
        let exchangeStateCleared = await attempt("FHIR exchange identity and retry state") {
            try fhirExchangeStateStore(
                accountDataGeneration: LocalPreferencesStore.standard[.accountDataGeneration]
            ).reset()
        }
        await sensorKitFetcher.resetAllQueryAnchors()
        await clinicalRecordPermissions.resetTracking()

        guard historicalDataCleared,
              stagedFilesCleared,
              stagedHealthDataCleared,
              exchangeStateCleared else {
            throw PendingAccountDataCleanupError.failed
        }
        LocalPreferencesStore.standard[.pendingAccountDataCleanupRequired] = false
    }
}


extension MyHeartCountsStandard {
    func stageHistoricalHealthKitFile(
        at url: URL,
        accountDataGeneration: Int
    ) async throws {
        try await managedFileUpload.stage(
            url,
            category: .historicalHealthUpload,
            accountDataGeneration: accountDataGeneration
        )
    }

    func uploadSensorKitFile(
        at url: URL,
        for sensor: Sensor<some Any>,
        accountDataGeneration: Int
    ) async throws {
        try await managedFileUpload.stage(
            url,
            category: ManagedFileUpload.Category(sensor),
            accountDataGeneration: accountDataGeneration
        )
    }
}
