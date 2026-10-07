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
    static var enableDebugHealthKitNotifications: Bool {
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
        try await Self.handleNewSamples(addedSamples, through: healthObservationUploadDependencies)
    }


    func handleDeletedObjects<Sample>(
        _ deletedObjects: some Collection<HKDeletedObject> & Sendable,
        ofType sampleType: SampleType<Sample>,
        deletedAfter: Date?
    ) async throws -> HealthKitAnchorCommitAction? {
        guard try await shouldAcceptHealthKitDelivery else {
            return nil
        }
        try healthUploadStaging.add(deletedObjects, ofType: sampleType, deletedAfter: deletedAfter)
        return nil
    }
}


extension MyHeartCountsStandard {
    enum HealthObservationUploadError: Error {
        case healthDataCollectionUnavailable
        /// A HealthKit sample was routed to ``HealthObservationUploadStrategy/directFirestore``, which takes
        /// self-modelled observations only.
        case unsupportedStrategy
    }

    enum HealthObservationUploadStrategy {
        case queueLocally
        @available(*, deprecated, message: "Will be removed in a future update!")
        case directFirestore
        case firebaseStorage
    }

    /// What uploading health observations reaches beyond the observations themselves.
    ///
    /// The upload functions take it as an argument, so tests run every path that holds a HealthKit batch's
    /// reservations without a signed-in account, Firebase or the app's ledger.
    struct HealthObservationUploadDependencies: Sendable {
        /// Whether a live HealthKit delivery is staged (`true`) or consumed without staging (`false`); throws while
        /// the account cannot take one yet, so Grove keeps the delivery's anchor.
        let acceptsHealthKitDelivery: @Sendable () async throws -> Bool
        /// The signed-in participant the observations are attributed to.
        let subject: @Sendable () async throws -> FHIRExchangeSubject
        /// Stages the observations of the HealthKit types MHC models, one row each.
        let staging: HealthUploadStaging
        /// The store an ECG's waveform and symptoms are fetched from.
        let healthKit: HealthKit
        /// The exporter of an upload file's HealthKit samples, fenced to `accountDataGeneration`; called only for a file
        /// that has HealthKit samples.
        let exporter: @Sendable (_ accountDataGeneration: Int) throws -> HealthKitFHIRExporter
        /// Durably stages one upload file of new observations for `accountDataGeneration`.
        let stageFile: @Sendable (_ file: URL, _ accountDataGeneration: Int) async throws -> Void
        /// Where the uploads are logged.
        let logger: Logger
    }

    static let defaultHealthObservationFHIRExtensions: [any FHIRExtensionBuilderProtocol] = [
        .sampleUploadTimeZone, .mhcStudyRevision, .mhcAppRevision
    ]
    
    nonisolated private static let directFirestoreUploadDefaultBatchSize = 100

    /// The app's: the signed-in account, the staging, the exchange identity and ledger, and the live health uploads.
    private var healthObservationUploadDependencies: HealthObservationUploadDependencies {
        let firebaseConfiguration = firebaseConfiguration
        let ledger = fhirExchangeLedger
        let managedFileUpload = managedFileUpload
        return HealthObservationUploadDependencies(
            acceptsHealthKitDelivery: {
                try await self.shouldAcceptHealthKitDelivery
            },
            subject: {
                try await firebaseConfiguration.fhirExchangeSubject
            },
            staging: healthUploadStaging,
            healthKit: healthKit,
            exporter: { accountDataGeneration in
                try ledger.healthKitExporter(forBatchOf: accountDataGeneration)
            },
            stageFile: { file, accountDataGeneration in
                try await managedFileUpload.stage(file, category: .liveHealthUpload, accountDataGeneration: accountDataGeneration)
            },
            logger: logger
        )
    }
    
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
        let receipt = try await Self.uploadHealthObservations(
            consume observations,
            accountDataGeneration: LocalPreferencesStore.standard[.accountDataGeneration],
            uploadStrategy: uploadStrategy,
            through: healthObservationUploadDependencies
        )
        assert(receipt.isEmpty, "public upload path left exchange-event reservations")
    }
}


extension MyHeartCountsStandard {
    /// Handles one live HealthKit delivery: stages it when the account accepts it, returning the action that releases
    /// its reservations once Grove has committed the delivery's anchor, and consumes it without staging otherwise.
    static func handleNewSamples(
        _ samples: consuming some Collection<some HealthObservation & Sendable> & Sendable,
        through dependencies: HealthObservationUploadDependencies
    ) async throws -> HealthKitAnchorCommitAction? {
        guard try await dependencies.acceptsHealthKitDelivery() else {
            return nil
        }
        return try await stageNewSamples(
            consume samples,
            accountDataGeneration: LocalPreferencesStore.standard[.accountDataGeneration],
            through: dependencies
        )
    }

    /// Stages one live HealthKit delivery, returning the action that releases its reservations once Grove has
    /// committed the delivery's anchor.
    ///
    /// Nothing releases them earlier, so until the action runs a redelivery reproduces every staged byte.
    static func stageNewSamples(
        _ samples: consuming some Collection<some HealthObservation & Sendable> & Sendable,
        accountDataGeneration: Int,
        through dependencies: HealthObservationUploadDependencies
    ) async throws -> HealthKitAnchorCommitAction? {
        try await uploadHealthObservations(
            consume samples,
            accountDataGeneration: accountDataGeneration,
            uploadStrategy: nil,
            through: dependencies
        ).anchorCommitAction
    }

    /// Uploads `observations` by `uploadStrategy`, or the strategy their sample type takes, returning the
    /// reservations of their HealthKit samples. The caller completes them once its source cursor is committed.
    static func uploadHealthObservations<Observations: Collection & Sendable>( // swiftlint:disable:this function_body_length cyclomatic_complexity
        _ observations: consuming Observations,
        accountDataGeneration: Int,
        uploadStrategy: HealthObservationUploadStrategy?,
        through dependencies: HealthObservationUploadDependencies
    ) async throws -> HealthKitFHIRReservationReceipt where Observations.Element: HealthObservation {
        guard !observations.isEmpty, let sampleTypeIdentifier = observations.first?.sampleTypeIdentifier else {
            return HealthKitFHIRReservationReceipt()
        }
        try Swift::Task.checkCancellation()
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
                        try await Self.uploadHealthObservations(
                            observations,
                            accountDataGeneration: accountDataGeneration,
                            uploadStrategy: uploadStrategy,
                            through: dependencies
                        )
                    }
                }
                var receipts: [HealthKitFHIRReservationReceipt] = []
                for try await receipt in taskGroup {
                    receipts.append(receipt)
                }
                return HealthKitFHIRReservationReceipt(merging: receipts)
            }
        }
        let conversionInstant = Date.now
        let subject = try await dependencies.subject()
        let destination = try FHIRExchangeDestination.capture(
            accountID: subject.identity.value,
            accountDataGeneration: accountDataGeneration
        )
        let uploadStrategy = uploadStrategy ?? Self.uploadStrategy(forSampleType: sampleTypeIdentifier)
        switch uploadStrategy {
        case .queueLocally:
            return try await dependencies.staging.add(
                observations,
                commonSampleType: sampleTypeIdentifier,
                accountDataGeneration: accountDataGeneration
            )
        case .firebaseStorage:
            let numObservations = observations.count
            dependencies.logger.notice("Uploading \(numObservations) observations of type '\(sampleTypeIdentifier)' via zstd upload")
            let triggerDidUploadNotification = await showDebugWillUploadHealthDataUploadEventNotification(
                for: .new(sampleTypeTitle: sampleTypeIdentifier, count: numObservations, uploadStrategy: uploadStrategy)
            )
            try destination.validateCurrentAccount()
            // Only HealthKit samples build the exporter, and with it read the identity secret and the app facts.
            let exporter = dependencies.exporter
            var entries: [PreparedHealthObservationFHIRPayload.Entry] = []
            let export = try await Observations.Element.export(
                consume observations,
                at: conversionInstant,
                using: dependencies.healthKit,
                exporter: try exporter(accountDataGeneration)
            ) { entry in
                entries.append(entry)
            }
            guard !entries.isEmpty else {
                return export.receipt
            }
            let url = try HealthUploadBatch.write(entries, typePrefix: sampleTypeIdentifier)
            defer {
                try? FileManager.default.removeItem(at: url)
            }
            try Swift::Task.checkCancellation()
            try destination.validateCurrentAccount()
            try await dependencies.stageFile(url, accountDataGeneration)
            await triggerDidUploadNotification()
            return export.receipt
        case .directFirestore:
            // Self-modelled observations only: they need no exporter, so neither the identity secret, the app
            // facts, nor the ledger. A HealthKit sample asks for one and is refused here.
            var entries: [PreparedHealthObservationFHIRPayload.Entry] = []
            _ = try await Observations.Element.export(
                consume observations,
                at: conversionInstant,
                using: dependencies.healthKit,
                exporter: { () throws -> HealthKitFHIRExporter in
                    throw HealthObservationUploadError.unsupportedStrategy
                }()
            ) { entry in
                entries.append(entry)
            }
            for chunk in entries.chunks(ofCount: Self.directFirestoreUploadDefaultBatchSize) {
                try Swift::Task.checkCancellation()
                try destination.validateCurrentAccount()
                let triggerDidUploadNotification = await showDebugWillUploadHealthDataUploadEventNotification(
                    for: .new(sampleTypeTitle: sampleTypeIdentifier, count: chunk.count, uploadStrategy: uploadStrategy)
                )
                let firestoreBatch = Firestore.firestore().batch()
                for entry in chunk {
                    guard case .resource(let resource) = entry.content else {
                        throw HealthObservationUploadError.unsupportedStrategy
                    }
                    let document = try Self.healthObservationDocument(
                        forSampleType: entry.sourceTypeIdentifier,
                        id: entry.sourceID.uuidString,
                        destination: destination
                    )
                    dependencies.logger.notice("Uploading Health Resource to \(document.path)")
                    try firestoreBatch.setData(from: resource, forDocument: document)
                }
                try Swift::Task.checkCancellation()
                try destination.validateCurrentAccount()
                try await firestoreBatch.commit()
                await triggerDidUploadNotification()
            }
            return HealthKitFHIRReservationReceipt()
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
    private static func showDebugWillUploadHealthDataUploadEventNotification(
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
