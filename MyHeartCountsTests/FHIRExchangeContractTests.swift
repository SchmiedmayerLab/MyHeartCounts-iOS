//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFHIRContract
import GroveHealthKit
import GroveHealthKitFHIR
import GroveQuestionnaireFHIR
import GroveSensorKit
import GroveSensorKitFHIR
import HealthKit
import ModelsR4
@testable import MyHeartCounts
import Testing
@Suite
struct FHIRExchangeStateTests {
    private static var subject: FHIRExchangeSubject {
        get throws {
            try FHIRExchangeSubject(identity: BusinessIdentifier(
                system: FHIRExchangeIdentifiers.participant,
                value: "participant-test"
            ))
        }
    }

    private static func eventFacts(study: String? = "study-original") throws -> FHIRExchangeEventFacts {
        FHIRExchangeEventFacts(
            application: try ApplicationDevice(
                name: "My Heart Counts",
                bundleIdentifier: "edu.stanford.MyHeartCounts",
                version: "1",
                build: "1"
            ),
            host: try HostDevice(operatingSystemVersion: "26.0"),
            study: study.map { FHIRExchangeEventFacts.Study(id: $0, revision: 1) }
        )
    }

    @Test
    func eventReservationIsStableUntilSourceAcknowledgement() throws {
        let store = FHIRExchangeStateStore()
        let subject = try Self.subject
        let key = store.healthKitEventKey(
            subject: subject,
            sourceType: "HKQuantityTypeIdentifierStepCount",
            nativeRecordID: try #require(UUID(uuidString: "9512fc92-b514-4bcc-a157-050c41dac51d"))
        )
        let first = try store.event(
            key: key,
            recordedAt: Date(timeIntervalSince1970: 1_788_000_000),
            facts: Self.eventFacts()
        )
        let retry = try store.event(
            key: key,
            recordedAt: Date(timeIntervalSince1970: 1_799_000_000),
            facts: FHIRExchangeEventFacts(
                application: try ApplicationDevice(
                    name: "Changed",
                    bundleIdentifier: "edu.stanford.changed-on-retry",
                    version: "2"
                ),
                host: try HostDevice(operatingSystemVersion: "27.0"),
                study: FHIRExchangeEventFacts.Study(id: "study-changed-during-retry", revision: 2)
            )
        )
        #expect(retry == first)

        let receipt = HealthKitFHIRReservationReceipt(
            stateStore: store,
            eventKeys: CollectionOfOne(key)
        )
        #expect(receipt.anchorCommitAction != nil)
        receipt.completeAfterSourceAcknowledgement()
        let laterPublication = try store.event(
            key: key,
            recordedAt: Date(timeIntervalSince1970: 1_799_000_000),
            facts: Self.eventFacts(study: "study-after-completion")
        )
        #expect(laterPublication.sequence == first.sequence + 1)
        #expect(first.facts.study?.id == "study-original")
        #expect(retry.facts.study?.id == "study-original")
        #expect(laterPublication.facts.study?.id == "study-after-completion")
    }

    @Test
    func sensorDigestRejectsDriftAndClearsWithAcknowledgedBatch() throws {
        let store = FHIRExchangeStateStore()
        let subject = try Self.subject
        let coordinate = SensorKit.AcquisitionBatchCoordinate(
            cursorTimestamp: Date(timeIntervalSince1970: 1_788_000_000),
            resetGeneration: 2,
            sequence: 7
        )
        let batchKey = store.sensorKitBatchKey(
            subject: subject,
            acquisitionBatch: coordinate,
            sourceToken: "SRSensor.accelerometer",
            deviceProductType: "iPhone18,1"
        )
        let sourceID = SensorKitSourceRecordID.derived(
            acquisitionBatch: coordinate,
            sourceToken: "SRSensor.accelerometer",
            deviceProductType: "iPhone18,1",
            recordOrdinal: 0
        )
        let eventKey = store.sensorKitEventKey(batchKey: batchKey, sourceRecordID: sourceID)
        let firstEvent = try store.event(
            key: eventKey,
            recordedAt: Date(timeIntervalSince1970: 1_788_000_001),
            facts: Self.eventFacts()
        )
        try store.verifySensorRetryDigest(Data("first".utf8), batchKey: batchKey, sourceRecordID: sourceID)
        try store.verifySensorRetryDigest(Data("first".utf8), batchKey: batchKey, sourceRecordID: sourceID)
        #expect(throws: FHIRExchangeStateError.retryContentChanged(sourceRecordID: sourceID.value)) {
            try store.verifySensorRetryDigest(Data("changed".utf8), batchKey: batchKey, sourceRecordID: sourceID)
        }

        try store.completeSensorBatch(batchKey)
        try store.verifySensorRetryDigest(Data("changed".utf8), batchKey: batchKey, sourceRecordID: sourceID)
        let nextEvent = try store.event(
            key: eventKey,
            recordedAt: Date(timeIntervalSince1970: 1_788_000_002),
            facts: Self.eventFacts()
        )
        #expect(nextEvent.sequence == firstEvent.sequence + 1)
    }

    @Test
    func sensorPublicationDestinationRejectsLogoutAndAccountSwitch() throws {
        let destination = FHIRExchangeDestination(
            accountDataGeneration: 7,
            accountID: "account-a"
        )

        try FHIRExchangeDestination.validateWrites(
            for: destination.accountDataGeneration,
            currentGeneration: 7,
            cleanupPending: false
        )
        #expect(destination.accountID == "account-a")
        #expect(throws: FHIRExchangeDestinationError.accountChanged) {
            try FHIRExchangeDestination.validateWrites(
                for: destination.accountDataGeneration,
                currentGeneration: 8,
                cleanupPending: false
            )
        }
        #expect(throws: FHIRExchangeDestinationError.accountChanged) {
            try FHIRExchangeDestination.validateWrites(
                for: destination.accountDataGeneration,
                currentGeneration: 7,
                cleanupPending: true
            )
        }
    }

    @Test
    func sourceRepositoriesAreStoreScopedAndDistinct() throws {
        let store = FHIRExchangeStateStore()
        let subject = try Self.subject
        let health = try store.repositoryScope(.healthKit, subject: subject)
        let sensor = try store.repositoryScope(.sensorKit, subject: subject)
        let repeatedHealth = try store.repositoryScope(.healthKit, subject: subject)
        #expect(health != sensor)
        #expect(health == repeatedHealth)
        #expect(health.value.hasPrefix("healthkit:"))
        #expect(sensor.value.hasPrefix("sensorkit:"))
    }

    @Test
    func opaqueSystemsDeriveFromTheDeploymentRoot() throws {
        let store = FHIRExchangeStateStore()
        let scope = try store.identityScope()
        let root = "https://myheartcounts.stanford.edu/fhir/NamingSystem"

        #expect(scope.keyID == "store")
        #expect(scope.epoch.rawValue == "1")
        let expected: [(IdentifierSystem, String)] = [
            (scope.systems.opaque.sourceRecord, "\(root)/grove-source-record-v0/store/1"),
            (scope.systems.opaque.sourceOutput, "\(root)/grove-source-output-v0/store/1"),
            (scope.systems.opaque.writerRecord, "\(root)/grove-writer-record-v0/store/1"),
            (scope.systems.opaque.providerRecord, "\(root)/grove-provider-record-v0/store/1"),
            (scope.systems.opaque.providerOutput, "\(root)/grove-provider-output-v0/store/1"),
            (scope.systems.opaque.sourceArtifact, "\(root)/grove-source-artifact-v0/store/1"),
            (scope.systems.opaque.providerArtifact, "\(root)/grove-provider-artifact-v0/store/1"),
            (scope.systems.opaque.sourceContext, "\(root)/grove-source-context-v0/store/1"),
            (scope.systems.opaque.recordingDevice, "\(root)/grove-recording-device-v0/store/1"),
            (scope.systems.opaque.deviceSnapshot, "\(root)/grove-device-snapshot-v0/store/1"),
            (scope.systems.event, "\(root)/grove-event-v0"),
            (scope.systems.entryNode, "\(root)/grove-entry-node-v0")
        ]
        for (system, literal) in expected {
            #expect(system.rawValue == literal)
        }

        // The system and the value minted under it state the same key id and epoch.
        let record = try scope.sourceRecord(
            adapterID: "healthkit",
            sourceType: "HKQuantityTypeIdentifierStepCount",
            repositoryScope: try store.repositoryScope(.healthKit, subject: try Self.subject),
            nativeRecordID: "9512fc92-b514-4bcc-a157-050c41dac51d"
        ).identifier.identifier
        #expect(record.system == scope.systems.opaque.sourceRecord)
        #expect(record.value.hasPrefix("v0:store:1:"))
    }

    /// A known enrollment travels with its exact protocol revision, and an unenrolled event names none.
    @Test
    func eventContextBundlesTheEnrollmentItWasReservedUnder() throws {
        let store = FHIRExchangeStateStore()
        let subject = try Self.subject
        let enrolled = try store.event(key: "enrolled", recordedAt: .now, facts: Self.eventFacts())
        let unenrolled = try store.event(key: "unenrolled", recordedAt: .now, facts: Self.eventFacts(study: nil))

        let study = try #require(
            try store.eventContext(for: enrolled, subject: subject, repository: .healthKit).studies.first
        )
        #expect(study.study.value == "study-original")
        #expect(study.protocolURL.value?.url.absoluteString == "https://myheartcounts.stanford.edu/fhir/PlanDefinition/study-original")
        #expect(study.protocolVersion == "1")
        #expect(study.enrollment.value == "study-original:participant-test")
        #expect(try store.eventContext(for: unenrolled, subject: subject, repository: .healthKit).studies.isEmpty)
    }

    @Test
    func unsupportedPersistedSchemaFailsClosed() throws {
        let store = FHIRExchangeStateStore(testingSchemaVersion: 1)
        #expect(throws: FHIRExchangeStateError.unsupportedSchemaVersion(1)) {
            try store.event(
                key: "schema-check",
                recordedAt: Date(timeIntervalSince1970: 1_788_000_000),
                facts: Self.eventFacts()
            )
        }
    }

    @Test
    func accountCleanupFencesLateOldGenerationMutations() throws {
        let oldStore = FHIRExchangeStateStore(accountDataGeneration: 7)
        let subject = try Self.subject
        let oldRepository = try oldStore.repositoryScope(.healthKit, subject: subject)
        let eventKey = oldStore.healthKitEventKey(
            subject: subject,
            sourceType: "HKQuantityTypeIdentifierStepCount",
            nativeRecordID: UUID()
        )
        _ = try oldStore.event(
            key: eventKey,
            recordedAt: Date(timeIntervalSince1970: 1_788_000_000),
            facts: Self.eventFacts()
        )
        let oldStateWasPersisted = try oldStore.hasPersistedStateForTesting
        #expect(oldStateWasPersisted)

        let newStore = oldStore.testingView(accountDataGeneration: 8)
        try newStore.reset()
        // The scope is store-bound and partitioned by the subject, so the same account keeps
        // its repository across a ledger reset; a different account gets its own partition.
        let newRepository = try newStore.repositoryScope(.healthKit, subject: subject)
        let newStateWasPersisted = try newStore.hasPersistedStateForTesting
        #expect(newRepository == oldRepository)
        #expect(newStateWasPersisted)

        #expect(throws: FHIRExchangeStateError.staleAccountGeneration(captured: 7, current: 8)) {
            _ = try oldStore.event(
                key: "late-old-account-reservation",
                recordedAt: Date(timeIntervalSince1970: 1_788_000_001),
                facts: Self.eventFacts()
            )
        }

        let newEvent = try newStore.event(
            key: eventKey,
            recordedAt: Date(timeIntervalSince1970: 1_788_000_002),
            facts: Self.eventFacts()
        )
        try oldStore.completeExchangeEvents(CollectionOfOne(eventKey))
        try oldStore.completeSensorBatch("late-account-a-batch")
        let retry = try newStore.event(
            key: eventKey,
            recordedAt: Date(timeIntervalSince1970: 1_799_000_000),
            facts: Self.eventFacts()
        )
        #expect(retry == newEvent)
    }
}
