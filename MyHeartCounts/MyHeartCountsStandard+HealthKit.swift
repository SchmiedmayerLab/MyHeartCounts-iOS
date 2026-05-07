//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Algorithms
import AsyncAlgorithms
import FirebaseFirestore
import FirebaseFunctions
import Foundation
import HealthKit
import HealthKitOnFHIR
@preconcurrency import ModelsDSTU2
@preconcurrency import ModelsR4
import MyHeartCountsShared
import OSLog
import SpeziAccount
import SpeziFHIR
import SpeziFoundation
import SpeziHealthKit
import SpeziStudy
import UserNotifications


extension LocalPreferenceKeys {
    static let sendHealthSampleUploadNotifications = LocalPreferenceKey<Bool>("sendHealthSampleUploadNotifications", default: false)
    
    static let sendSensorKitUploadNotifications = LocalPreferenceKey<Bool>("sendSensorKitUploadNotifications", default: false)
    
    /// the last-seen value of the ``SpeziAccount/AccountDetails/enableDebugMode`` account key value.
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
            guard let account, let studyManager else {
                return false
            }
            // we might continue receiving Health data for a bit after unenrolling; we want to ignore these.
            return await MainActor.run {
                account.signedIn && !studyManager.studyEnrollments.isEmpty
            }
        }
    }
    
    func handleNewSamples<Sample>(_ addedSamples: some Collection<Sample> & Sendable, ofType sampleType: SampleType<Sample>) async {
        guard await shouldCollectHealthData else {
            return
        }
        do {
            try await uploadHealthObservations(addedSamples, batchSize: 100)
        } catch {
            logger.error("Error uploading HealthKit samples: \(error)")
        }
    }
    
    
    func handleDeletedObjects<Sample>(_ deletedObjects: some Collection<HKDeletedObject> & Sendable, ofType sampleType: SampleType<Sample>) async {
        guard await shouldCollectHealthData else {
            return
        }
        let deletedObjects = Array(deletedObjects)
        logger.notice("\(#function) \(deletedObjects.count) deleted HKObjects for \(sampleType.mhcDisplayTitle)")
        let triggerDidUploadNotification = await showDebugWillUploadHealthDataUploadEventNotification(
            for: .deleted(sampleTypeTitle: sampleType.mhcDisplayTitle, count: deletedObjects.count)
        )
        guard let accountId = await account?.details?.accountId else {
            return
        }
        do {
            let collection = "HealthObservations_\(sampleType.id)"
            logger.notice("Will use bulk-delete function to delete \(deletedObjects.count) HealthKit object(s) for \(sampleType.id)")
            _ = try await Functions.functions()
                .httpsCallable("deleteHealthSamples")
                .call([
                    "userId": accountId,
                    "collection": collection,
                    "documentIds": deletedObjects.map(\.uuid.uuidString)
                ])
        } catch {
            logger.notice("Error calling bulk-delete function: \(error)")
        }
        await triggerDidUploadNotification()
    }
}


extension MyHeartCountsStandard {
    private enum HealthObservationUploadStrategy {
        case directFirestore
        case firebaseStorage
    }
    
    
    // NOTE: This is in fact concurrency-safe; we're just missing a `FHIRExtensionBuilderProtocol: Sendable` requirement in HKoF.
    nonisolated(unsafe) static let defaultHealthObservationFHIRExtensions: [any FHIRExtensionBuilderProtocol] = [
        .sampleUploadTimeZone, .mhcStudyRevision
    ]
    
    /// Determines how a health observation / resource should be persisted when uploading it to firebase.
    private static func uploadStrategy(forSampleType identifier: String) -> HealthObservationUploadStrategy {
        if identifier == TimedWalkingTestResult.sampleTypeIdentifier {
            return .directFirestore
        }
        return switch MHCSampleType(sampleTypeIdentifier: identifier) {
        case nil, .healthKit:
            .firebaseStorage
        case .custom:
            .directFirestore
        }
    }
    
    func uploadHealthObservation(
        _ observation: some HealthObservation & Sendable,
        postprocessResource: @escaping @Sendable (FHIRResource) throws -> Void = { _ in }
    ) async throws {
        try await uploadHealthObservations(
            CollectionOfOne(observation),
            batchSize: 1,
            postprocessResource: postprocessResource
        )
    }
    
    func uploadHealthObservations( // swiftlint:disable:this function_body_length cyclomatic_complexity
        _ observations: consuming some Collection<some HealthObservation & Sendable> & Sendable,
        batchSize: Int = 100,
        postprocessResource: @escaping @Sendable (FHIRResource) throws -> Void = { _ in }
    ) async throws {
        guard !observations.isEmpty, let sampleTypeIdentifier = observations.first?.sampleTypeIdentifier else {
            return
        }
        guard observations.allSatisfy({ $0.sampleTypeIdentifier == sampleTypeIdentifier }) else {
            // in the unlikely case of the caller passing in heterogeneous health observations, we process each sample type individually
            try await withThrowingDiscardingTaskGroup { taskGroup in
                let bySampleType = observations.grouped(by: \.sampleTypeIdentifier)
                for (_, observations) in bySampleType {
                    taskGroup.addTask {
                        try await self.uploadHealthObservations(observations, batchSize: batchSize, postprocessResource: postprocessResource)
                    }
                }
            }
            return
        }
        let issuedDate = FHIRPrimitive<ModelsR4.Instant>(try .init(date: .now))
        @concurrent
        func turnIntoFHIRResource(_ observation: some HealthObservation) async throws -> AnyEncodable? {
            switch observation {
            case let sample as HKElectrocardiogram:
                let symptoms = try await sample.symptoms(from: healthKit)
                let voltages = try await sample.voltageMeasurements(from: healthKit.healthStore)
                let observation = try sample.observation(
                    symptoms: symptoms,
                    voltageMeasurements: voltages.map { (time: $0.timeOffset, value: $0.voltage) },
                    withMapping: .default,
                    issuedDate: issuedDate,
                    extensions: Self.defaultHealthObservationFHIRExtensions
                )
                try postprocessResource(FHIRResource(observation))
                return AnyEncodable(observation)
            case let record as HKClinicalRecord:
                guard record.fhirResource != nil else {
                    // just fail silently...
                    self.logger.error("Skipping HKClinicalRecord, bc no fhirResource")
                    return nil
                }
                let resource = try await FHIRResource(record, using: healthKit)
                switch resource {
                case .dstu2(let resource):
                    (resource as? ModelsDSTU2.DomainResource)?.addSourceRevisionExtensions(for: record.sourceRevision)
                case .r4(let resource):
                    (resource as? ModelsR4.DomainResource)?.addSourceRevisionExtensions(for: record.sourceRevision)
                }
                try postprocessResource(resource)
                return AnyEncodable(resource)
            default:
                let resource = try observation.resource(
                    withMapping: .default,
                    issuedDate: issuedDate,
                    extensions: Self.defaultHealthObservationFHIRExtensions
                )
                try postprocessResource(FHIRResource(resource.get()))
                return AnyEncodable(resource)
            }
        }
        let uploadStrategy = Self.uploadStrategy(forSampleType: sampleTypeIdentifier)
        switch uploadStrategy {
        case .firebaseStorage:
            let numObservations = observations.count
            logger.notice("Uploading \(numObservations) observations of type '\(sampleTypeIdentifier)' via zstd upload")
            let triggerDidUploadNotification = await showDebugWillUploadHealthDataUploadEventNotification(
                for: .new(sampleTypeTitle: sampleTypeIdentifier, count: numObservations, uploadStrategy: uploadStrategy)
            )
            let resources: [AnyEncodable] = try await (consume observations).async.reduce(into: []) { resources, observation in
                if let resource = try await turnIntoFHIRResource(observation) {
                    resources.append(resource)
                }
            }
            guard !resources.isEmpty else {
                return
            }
            let encoded = try JSONEncoder().encode(consume resources)
            let compressed = try (consume encoded).compressed(using: Zstd.self)
            let url = URL.temporaryDirectory.appending(path: "\(sampleTypeIdentifier)_\(UUID().uuidString).json.zstd", directoryHint: .notDirectory)
            try (consume compressed).write(to: url)
            _Concurrency.Task {
                try await managedFileUpload.upload(url, category: .liveHealthUpload)
                await triggerDidUploadNotification()
            }
        case .directFirestore:
            for chunk in (consume observations).chunks(ofCount: batchSize) {
                let triggerDidUploadNotification = await showDebugWillUploadHealthDataUploadEventNotification(
                    for: .new(sampleTypeTitle: sampleTypeIdentifier, count: chunk.count, uploadStrategy: uploadStrategy)
                )
                let batch = Firestore.firestore().batch()
                for observation in chunk {
                    do {
                        let document = try await healthObservationDocument(for: observation)
                        let path = document.path
                        logger.notice("Uploading Health Resource to \(path)")
                        if let resource = try await turnIntoFHIRResource(observation) {
                            try batch.setData(from: consume resource, forDocument: document)
                        }
                    } catch {
                        logger.error("Error saving health observation to Firebase: \(error); input: \(String(describing: observation))")
                    }
                }
                try await batch.commit()
                await triggerDidUploadNotification()
            }
        }
    }
    
    
    private func healthObservationDocument(for observation: some HealthObservation) async throws -> FirebaseFirestore.DocumentReference {
        try await healthObservationDocument(forSampleType: observation.sampleTypeIdentifier, id: observation.id)
    }
    
    private func healthObservationDocument(
        forSampleType sampleTypeIdentifier: String,
        id: UUID
    ) async throws -> FirebaseFirestore.DocumentReference {
        try await firebaseConfiguration.userDocumentReference
            .collection("HealthObservations_\(sampleTypeIdentifier)")
            .document(id.uuidString)
    }
}


extension MyHeartCountsStandard {
    private enum HealthDocumentChange {
        case new(sampleTypeTitle: String, count: Int, uploadStrategy: HealthObservationUploadStrategy)
        case deleted(sampleTypeTitle: String, count: Int)
    }
    
    private static func notificationLabel(for uploadStrategy: HealthObservationUploadStrategy) -> String {
        switch uploadStrategy {
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

extension FHIRExtensionUrls {
    // SAFETY: this is in fact safe, since the FHIRPrimitive's `extension` property is empty.
    // As a result, the actual instance doesn't contain any mutable state, and since this is a let,
    // it also never can be mutated to contain any.
    /// Url of a FHIR Extension containing the user's time zone when uploading a FHIR `Observation`.
    nonisolated(unsafe) static let sampleUploadTimeZone: ModelsR4.FHIRPrimitive<_> = "https://bdh.stanford.edu/fhir/defs/sampleUploadTimeZone".asFHIRURIPrimitive()!
    // swiftlint:disable:previous force_unwrapping
    
    // SAFETY: this is in fact safe, since the FHIRPrimitive's `extension` property is empty.
    // As a result, the actual instance doesn't contain any mutable state, and since this is a let,
    // it also never can be mutated to contain any.
    /// Url of a FHIR Extension containing the user's enrollment info uploading a FHIR `Observation`.
    nonisolated(unsafe) static let mhcStudyEnrollmentInfo: ModelsR4.FHIRPrimitive<_> = "https://myheartcounts.stanford.edu/fhir/StructureDefinition/study-enrollment".asFHIRURIPrimitive()!
    // swiftlint:disable:previous force_unwrapping
}

extension FHIRExtensionBuilderProtocol where Self == FHIRExtensionBuilder<Void> {
    static var sampleUploadTimeZone: Self {
        .init { observation in
            let ext = Extension(
                url: FHIRExtensionUrls.sampleUploadTimeZone,
                value: .string(TimeZone.current.identifier.asFHIRStringPrimitive())
            )
            observation.appendExtension(ext, replaceAllExistingWithSameUrl: true)
        }
    }
    
    
    static var mhcStudyRevision: Self {
        .init { observation in
            guard let enrollmentInfo = MyHeartCountsStandard.currentEnrollmentInfo else {
                return
            }
            let extUrl = FHIRExtensionUrls.mhcStudyEnrollmentInfo
            let ext = Extension(url: extUrl)
            ext.extension = [
                Extension(
                    url: extUrl.appending(component: "study-id"),
                    value: .string(enrollmentInfo.studyId.asFHIRStringPrimitive())
                ),
                Extension(
                    url: extUrl.appending(component: "study-revision"),
                    value: .integer(Int(enrollmentInfo.studyRevision).asFHIRIntegerPrimitive())
                )
            ]
            observation.appendExtension(ext, replaceAllExistingWithSameUrl: true)
        }
    }
}
