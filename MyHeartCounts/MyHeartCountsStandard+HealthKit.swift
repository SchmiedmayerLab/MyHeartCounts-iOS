//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Algorithms
import FHIRModelsExtensions
import FirebaseFirestore
import Foundation
import GroveAccount
import GroveFHIR
import GroveFHIRContract
import GroveFoundation
import GroveHealthKit
import GroveHealthKitFHIR
import GroveStudy
import HealthKit
import ModelsR4
import MyHeartCountsShared
import OSLog
import UserNotifications


extension LocalPreferenceKeys {
    static let sendHealthSampleUploadNotifications = LocalPreferenceKey<Bool>("sendHealthSampleUploadNotifications", default: false)
    
    static let sendSensorKitUploadNotifications = LocalPreferenceKey<Bool>("sendSensorKitUploadNotifications", default: false)
    
    /// the last-seen value of the ``GroveAccount/AccountDetails/enableDebugMode`` account key value.
    ///
    /// we need this to be able to access the account key value immediately after launch,
    /// where it typically isn't yet available if the account details haven't yet been delivered to the Standard.
    static let lastSeenIsDebugModeEnabledAccountKey = LocalPreferenceKey<Bool>("lastSeenIsDebugModeEnabledAccountKey", default: false)
}


extension MyHeartCountsStandard: HealthKitConstraint {
    var enableDebugHealthKitNotifications: Bool {
        let prefs = LocalPreferencesStore.standard
        return prefs[.lastSeenIsDebugModeEnabledAccountKey] && prefs[.sendHealthSampleUploadNotifications]
    }
    
    var enableDebugSensorKitNotifications: Bool {
        let prefs = LocalPreferencesStore.standard
        return prefs[.lastSeenIsDebugModeEnabledAccountKey] && prefs[.sendSensorKitUploadNotifications]
    }
    
    var shouldCollectHealthData: Bool {
        get async {
            guard !LocalPreferencesStore.standard[.pendingAccountDataCleanupRequired] else {
                return false
            }
            guard let account, let studyManager else {
                return false
            }
            // we might continue receiving Health data for a bit after unenrolling; we want to ignore these.
            return await MainActor.run {
                account.signedIn && !studyManager.studyEnrollments.isEmpty
            }
        }
    }

    /// Whether a live HealthKit delta may be acknowledged to Grove.
    ///
    /// Being signed in without an enrollment intentionally consumes late delivery after an
    /// unenrollment. Missing account state is temporary and must retain the query anchor.
    private var shouldAcceptHealthKitDelivery: Bool {
        get async throws {
            guard !LocalPreferencesStore.standard[.pendingAccountDataCleanupRequired],
                  let account,
                  let studyManager else {
                throw HealthObservationUploadError.healthDataCollectionUnavailable
            }
            let (signedIn, enrolled) = await MainActor.run {
                (account.signedIn, !studyManager.studyEnrollments.isEmpty)
            }
            guard signedIn else {
                throw HealthObservationUploadError.healthDataCollectionUnavailable
            }
            return enrolled
        }
    }

    func handleNewSamples<Sample>(
        _ addedSamples: some Collection<Sample> & Sendable,
        ofType sampleType: SampleType<Sample>
    ) async throws -> HealthKitAnchorCommitAction? {
        guard try await shouldAcceptHealthKitDelivery else {
            return nil
        }
        let receipt = try await uploadHealthObservations(
            addedSamples,
            accountDataGeneration: LocalPreferencesStore.standard[.accountDataGeneration],
            uploadStrategy: nil
        )
        return receipt.anchorCommitAction
    }


    func handleDeletedObjects<Sample>(
        _ deletedObjects: some Collection<HKDeletedObject> & Sendable,
        ofType sampleType: SampleType<Sample>
    ) async throws -> HealthKitAnchorCommitAction? {
        guard try await shouldAcceptHealthKitDelivery else {
            return nil
        }
        try healthUploadStaging.add(deletedObjects, ofType: sampleType)
        return nil
    }
}


extension MyHeartCountsStandard {
    private enum HealthObservationUploadError: Error {
        case healthDataCollectionUnavailable
    }

    enum HealthObservationUploadStrategy {
        case queueLocally
        case directFirestore
        case firebaseStorage
    }
    
    
    static let defaultHealthObservationFHIRExtensions: [any FHIRExtensionBuilderProtocol] = [
        .sampleUploadTimeZone, .mhcStudyRevision, .mhcAppRevision
    ]
    
    nonisolated private static let directFirestoreUploadDefaultBatchSize = 100
    
    /// Determines how a health observation / resource should be persisted when uploading it to firebase.
    private static func uploadStrategy(forSampleType identifier: String) -> HealthObservationUploadStrategy {
        if identifier == TimedWalkingTestResult.sampleTypeIdentifier {
            return .directFirestore
        }
        return switch MHCSampleType(sampleTypeIdentifier: identifier) {
        case nil:
            .firebaseStorage
        case .healthKit:
            .queueLocally
        case .custom:
            .directFirestore
        }
    }
    
    /// The one document address every health observation is written to, validated before use.
    static func healthObservationDocument(
        forSampleType sampleTypeIdentifier: String,
        id: String,
        destination: FHIRExchangeDestination
    ) throws -> FirebaseFirestore.DocumentReference {
        try destination.validateCurrentAccount()
        return FirebaseConfiguration.usersCollection
            .document(destination.accountID)
            .collection("HealthObservations_\(sampleTypeIdentifier)")
            .document(id)
    }

    func uploadHealthObservation(_ observation: some HealthObservation & Sendable) async throws {
        try await uploadHealthObservations(CollectionOfOne(observation))
    }
    
    /// Uploads ``HealthObservation``s to the backend.
    ///
    /// - parameter observations: The health observations that should be uploaded.
    /// - parameter uploadStrategy: How the observations should be uploaded. Specify `nil` (the default) to have the function determine a suitable upload destination.
    func uploadHealthObservations(
        _ observations: consuming some Collection<some HealthObservation & Sendable> & Sendable,
        uploadStrategy: HealthObservationUploadStrategy? = nil
    ) async throws {
        // Every public caller passes self-modelled observations, which reserve no exchange events.
        let receipt = try await uploadHealthObservations(
            consume observations,
            accountDataGeneration: LocalPreferencesStore.standard[.accountDataGeneration],
            uploadStrategy: uploadStrategy
        )
        assert(receipt.eventKeys.isEmpty, "public upload path left \(receipt.eventKeys.count) reservations")
    }

    private func uploadHealthObservations( // swiftlint:disable:this function_body_length cyclomatic_complexity
        _ observations: consuming some Collection<some HealthObservation & Sendable> & Sendable,
        accountDataGeneration: Int,
        uploadStrategy: HealthObservationUploadStrategy?
    ) async throws -> HealthKitFHIRReservationReceipt {
        guard !observations.isEmpty, let sampleTypeIdentifier = observations.first?.sampleTypeIdentifier else {
            return HealthKitFHIRReservationReceipt()
        }
        try _Concurrency.Task.checkCancellation()
        try FHIRExchangeDestination.validateWrites(for: accountDataGeneration)
        guard observations.allSatisfy({ $0.sampleTypeIdentifier == sampleTypeIdentifier }) else {
            // in the unlikely case of the caller passing in heterogeneous health observations, we process each sample type individually
            return try await withThrowingTaskGroup(
                of: HealthKitFHIRReservationReceipt.self,
                returning: HealthKitFHIRReservationReceipt.self
            ) { taskGroup in
                let bySampleType = observations.grouped(by: \.sampleTypeIdentifier)
                for (_, observations) in bySampleType {
                    taskGroup.addTask {
                        try await self.uploadHealthObservations(
                            observations,
                            accountDataGeneration: accountDataGeneration,
                            uploadStrategy: uploadStrategy
                        )
                    }
                }
                var eventKeys = Set<String>()
                for try await receipt in taskGroup {
                    eventKeys.formUnion(receipt.eventKeys)
                }
                return HealthKitFHIRReservationReceipt(
                    stateStore: self.fhirExchangeStateStore(
                        accountDataGeneration: accountDataGeneration
                    ),
                    eventKeys: eventKeys
                )
            }
        }
        let conversionInstant = Date.now
        let subject = try await firebaseConfiguration.fhirExchangeSubject
        let destination = try FHIRExchangeDestination.capture(
            accountID: subject.identity.value,
            accountDataGeneration: accountDataGeneration
        )
        let stateStore = fhirExchangeStateStore(accountDataGeneration: accountDataGeneration)
        func prepareFHIRPayload(
            _ observation: some HealthObservation
        ) async throws -> PreparedHealthObservationFHIRPayload {
            try await observation.prepareFHIRPayload(
                conversionInstant: conversionInstant,
                subject: subject,
                stateStore: stateStore,
                using: healthKit
            )
        }
        let uploadStrategy = uploadStrategy ?? Self.uploadStrategy(forSampleType: sampleTypeIdentifier)
        switch uploadStrategy {
        case .queueLocally:
            return try await healthUploadStaging.add(
                observations,
                commonSampleType: sampleTypeIdentifier,
                accountDataGeneration: accountDataGeneration
            )
        case .firebaseStorage:
            let numObservations = observations.count
            logger.notice("Uploading \(numObservations) observations of type '\(sampleTypeIdentifier)' via zstd upload")
            let triggerDidUploadNotification = await showDebugWillUploadHealthDataUploadEventNotification(
                for: .new(sampleTypeTitle: sampleTypeIdentifier, count: numObservations, uploadStrategy: uploadStrategy)
            )
            var entries: [PreparedHealthObservationFHIRPayload.Entry] = []
            for observation in consume observations {
                try _Concurrency.Task.checkCancellation()
                try destination.validateCurrentAccount()
                let payload = try await prepareFHIRPayload(observation)
                entries.append(contentsOf: payload.entries)
            }
            guard !entries.isEmpty else {
                return HealthKitFHIRReservationReceipt(stateStore: stateStore, entries: entries)
            }
            let url = try HealthUploadBatch.write(entries, typePrefix: sampleTypeIdentifier)
            defer {
                try? FileManager.default.removeItem(at: url)
            }
            try _Concurrency.Task.checkCancellation()
            try destination.validateCurrentAccount()
            try await managedFileUpload.stage(
                url,
                category: .liveHealthUpload,
                accountDataGeneration: accountDataGeneration
            )
            await triggerDidUploadNotification()
            return HealthKitFHIRReservationReceipt(stateStore: stateStore, entries: entries)
        case .directFirestore:
            var acknowledgedEventKeys = Set<String>()
            for chunk in (consume observations).chunks(ofCount: Self.directFirestoreUploadDefaultBatchSize) {
                try _Concurrency.Task.checkCancellation()
                try destination.validateCurrentAccount()
                let triggerDidUploadNotification = await showDebugWillUploadHealthDataUploadEventNotification(
                    for: .new(sampleTypeTitle: sampleTypeIdentifier, count: chunk.count, uploadStrategy: uploadStrategy)
                )
                let batch = Firestore.firestore().batch()
                var chunkEventKeys = Set<String>()
                for observation in chunk {
                    let payload = try await prepareFHIRPayload(observation)
                    for entry in payload.entries {
                        if let eventKey = entry.eventKey {
                            chunkEventKeys.insert(eventKey)
                        }
                        let document = try Self.healthObservationDocument(
                            forSampleType: entry.sourceTypeIdentifier,
                            id: entry.sourceID.uuidString,
                            destination: destination
                        )
                        logger.notice("Uploading Health Resource to \(document.path)")
                        try batch.setData(from: entry.resource, forDocument: document)
                    }
                }
                try _Concurrency.Task.checkCancellation()
                try destination.validateCurrentAccount()
                try await batch.commit()
                acknowledgedEventKeys.formUnion(chunkEventKeys)
                await triggerDidUploadNotification()
            }
            return HealthKitFHIRReservationReceipt(
                stateStore: stateStore,
                eventKeys: acknowledgedEventKeys
            )
        }
    }
}


extension MyHeartCountsStandard {
    private enum HealthDocumentChange {
        case new(sampleTypeTitle: String, count: Int, uploadStrategy: HealthObservationUploadStrategy)
        case deleted(sampleTypeTitle: String, count: Int)
    }
    
    private static func notificationLabel(for uploadStrategy: HealthObservationUploadStrategy) -> String {
        switch uploadStrategy {
        case .queueLocally:
            "queueLocally"
        case .directFirestore:
            "direct"
        case .firebaseStorage:
            "storage"
        }
    }
    
    /// - returns: A closure that should be called upon completion of the uploads, and will replaces the "will upload" notifications with "did upload" notifications.
    private func showDebugWillUploadHealthDataUploadEventNotification(
        for change: HealthDocumentChange
    ) async -> @Sendable () async -> Void {
        guard enableDebugHealthKitNotifications else {
            return {}
        }
        @Sendable
        func imp(stage: String) async -> String {
            let notificationCenter = UNUserNotificationCenter.current()
            let content = UNMutableNotificationContent()
            switch change {
            case let .new(sampleTypeTitle, count, uploadStrategy):
                content.title = "\(stage) upload new health observations"
                content.body = "\(count) new observations for \(sampleTypeTitle). mode: \(Self.notificationLabel(for: uploadStrategy))"
            case let .deleted(sampleTypeTitle, count):
                content.title = "\(stage) delete health observations"
                content.body = "\(count) deleted observations for \(sampleTypeTitle)"
            }
            let identifier = UUID().uuidString
            let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
            try? await notificationCenter.add(request)
            return identifier
        }
        
        let notificationId = await imp(stage: "Will")
        return {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [notificationId])
            _ = await imp(stage: "Did")
        }
    }
}


// MARK: FHIR Observation Metadata

extension FHIRExtensionURL {
    /// Url of a FHIR Extension containing the user's time zone when uploading a FHIR `Observation`.
    static let sampleUploadTimeZone = try! Self( // swiftlint:disable:this force_try
        "https://myheartcounts.stanford.edu/fhir/core/sampleUploadTimeZone"
    )
    
    /// Url of a FHIR Extension containing the user's enrollment info uploading a FHIR `Observation`.
    static let mhcStudyEnrollmentInfo = try! Self( // swiftlint:disable:this force_try
        "https://myheartcounts.stanford.edu/fhir/StructureDefinition/study-enrollment"
    )
}


extension FHIRExtensionBuilderProtocol where Self == FHIRExtensionBuilder<Void> {
    static var sampleUploadTimeZone: Self {
        .init { resource in
            let ext = Extension(
                url: FHIRExtensionURL.sampleUploadTimeZone,
                value: .string(TimeZone.current.identifier.asFHIRStringPrimitive())
            )
            resource.append(extension: ext, behaviour: .replace)
        }
    }
    
    static var mhcStudyRevision: Self {
        .init { resource in
            guard let enrollmentInfo = MyHeartCountsStandard.currentEnrollmentInfo else {
                return
            }
            let extUrl = FHIRExtensionURL.mhcStudyEnrollmentInfo
            let ext = Extension(
                extension: [
                    Extension(
                        url: extUrl.appending(component: "study-id"),
                        value: .string(enrollmentInfo.studyId.asFHIRStringPrimitive())
                    ),
                    Extension(
                        url: extUrl.appending(component: "study-revision"),
                        value: .integer(Int(enrollmentInfo.studyRevision).asFHIRIntegerPrimitive())
                    )
                ],
                url: extUrl
            )
            resource.append(extension: ext, behaviour: .replace)
        }
    }
}
