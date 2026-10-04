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
        let key = store.questionnaireEventKey(subject: subject, responseID: "9512fc92-b514-4bcc-a157-050c41dac51d")
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

        try store.completeExchangeEvents(CollectionOfOne(key))
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
        let firstZone = try #require(TimeZone(identifier: "America/St_Johns"))
        #expect(try store.sensorBatchTimeZone(batchKey, current: firstZone) == firstZone)
        try store.verifySensorRetryDigest(Data("first".utf8), batchKey: batchKey, sourceRecordID: sourceID)
        try store.verifySensorRetryDigest(Data("first".utf8), batchKey: batchKey, sourceRecordID: sourceID)
        #expect(throws: FHIRExchangeStateError.retryContentChanged(sourceRecordID: sourceID.value)) {
            try store.verifySensorRetryDigest(Data("changed".utf8), batchKey: batchKey, sourceRecordID: sourceID)
        }
        #expect(try store.sensorBatchTimeZone(batchKey, current: .gmt) == firstZone)

        try store.completeSensorBatch(batchKey)
        try store.verifySensorRetryDigest(Data("changed".utf8), batchKey: batchKey, sourceRecordID: sourceID)
        #expect(try store.sensorBatchTimeZone(batchKey, current: .gmt) == .gmt)
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

    /// A known enrollment travels with its exact protocol revision, and an unenrolled producer names none.
    @Test
    func eventFactsStateTheEnrollmentWithItsProtocolRevision() throws {
        let subject = try Self.subject
        let studyID = "7C1A5E0F-3B2D-4E6A-9F8B-0D1C2E3F4A5B"

        let study = try #require(try Self.eventFacts(study: studyID).studies(for: subject).first)
        let lowercased = "7c1a5e0f-3b2d-4e6a-9f8b-0d1c2e3f4a5b"
        #expect(study.study.value == lowercased)
        #expect(study.protocolURL.value?.url.absoluteString == "https://myheartcounts.stanford.edu/fhir/PlanDefinition/\(lowercased)")
        #expect(study.protocolVersion == "1")
        #expect(study.enrollment.value == "\(lowercased):participant-test")
        #expect(try Self.eventFacts(study: nil).studies(for: subject).isEmpty)
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
        let eventKey = oldStore.questionnaireEventKey(subject: subject, responseID: UUID().uuidString)
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


// MARK: Batch Reservation

extension FHIRExchangeStateTests {
    /// A batch mints consecutive sequences for its new keys in input order in one transaction.
    @Test
    func batchReservationMintsNewKeysInInputOrder() throws {
        let store = FHIRExchangeStateStore()
        let recordedAt = Date(timeIntervalSince1970: 1_788_000_000)
        let existing = try store.event(key: "existing", recordedAt: recordedAt, facts: Self.eventFacts())
        let batch = try store.events(
            forKeys: ["new-a", "existing", "new-b"],
            recordedAt: recordedAt + 60,
            facts: Self.eventFacts(study: "study-of-the-batch")
        )

        #expect(batch.events.map(\.sequence) == [existing.sequence + 1, existing.sequence, existing.sequence + 2])
        #expect(batch.events[1] == existing)
        #expect(batch.events[0].recordedAt == recordedAt + 60)
        #expect(batch.events[2].facts.study?.id == "study-of-the-batch")
        #expect(try batch.producerInstance == store.producerInstance())
    }

    /// Keys that are all reserved already come back unchanged and consume no sequence.
    @Test
    func batchReservationReturnsExistingEventsWithoutConsumingSequences() throws {
        let store = FHIRExchangeStateStore()
        let recordedAt = Date(timeIntervalSince1970: 1_788_000_000)
        let first = try store.events(forKeys: ["a", "b"], recordedAt: recordedAt, facts: Self.eventFacts())
        let retry = try store.events(
            forKeys: ["b", "a"],
            recordedAt: recordedAt + 3600,
            facts: Self.eventFacts(study: "study-changed-during-retry")
        )

        #expect(retry.events == [first.events[1], first.events[0]])
        #expect(retry.producerInstance == first.producerInstance)
        let next = try store.event(key: "c", recordedAt: recordedAt, facts: Self.eventFacts())
        #expect(next.sequence == first.events[1].sequence + 1)
    }

    /// A late publisher of a rotated account is fenced whether its keys hit or miss the ledger.
    @Test
    func batchReservationRejectsStaleAccountGeneration() throws {
        let oldStore = FHIRExchangeStateStore(accountDataGeneration: 7)
        let recordedAt = Date(timeIntervalSince1970: 1_788_000_000)
        _ = try oldStore.events(forKeys: ["shared"], recordedAt: recordedAt, facts: Self.eventFacts())
        let newStore = oldStore.testingView(accountDataGeneration: 8)
        try newStore.reset()
        let newEvents = try newStore.events(forKeys: ["shared"], recordedAt: recordedAt, facts: Self.eventFacts())

        let stale = FHIRExchangeStateError.staleAccountGeneration(captured: 7, current: 8)
        #expect(throws: stale) {
            try oldStore.events(forKeys: ["shared"], recordedAt: recordedAt, facts: Self.eventFacts())
        }
        #expect(throws: stale) {
            try oldStore.events(forKeys: ["shared", "late"], recordedAt: recordedAt, facts: Self.eventFacts())
        }
        let retry = try newStore.events(forKeys: ["shared"], recordedAt: recordedAt, facts: Self.eventFacts())
        #expect(retry.events == newEvents.events)
    }

    /// A staged HealthKit delivery reserves every sample before converting any; a redelivery of one of them,
    /// alone or later, reproduces the event the delivery minted until its anchor commits.
    @Test
    func healthKitBatchReservesEverySampleUpFront() async throws {
        let staging = try await HealthUploadStaging.resolvedForTesting()
        let samples = (0..<3).map(LedgerHarness.steps)
        let delivery = try await staging.add(samples)
        let batch = try staging.drainStagedSamples().mapValues(stagedEvent)

        for sample in samples {
            _ = try await staging.add([sample])
            let single = try staging.drainStagedSamples().mapValues(stagedEvent)
            #expect(single == [sample.uuid: try #require(batch[sample.uuid])])
        }
        // New sequences follow the order of the event keys, not of the input.
        #expect(Set(batch.values.map(\.sequence.rawValue)) == ["1", "2", "3"])
        let unreserved = LedgerHarness.steps(3)
        _ = try await staging.add([unreserved])
        #expect(try staging.drainStagedSamples().mapValues(stagedEvent)[unreserved.uuid]?.sequence.rawValue == "4")
        try await delivery.commitAnchor()
    }
}


extension FHIRExchangeStateTests {
    @Test
    func abandoningSensorBatchesDropsOnlyThatSourcesRetryState() throws {
        let store = FHIRExchangeStateStore()
        let subject = try Self.subject
        let coordinate = SensorKit.AcquisitionBatchCoordinate(
            cursorTimestamp: Date(timeIntervalSince1970: 1_788_000_000),
            resetGeneration: 2,
            sequence: 7
        )
        func record(of sourceToken: String) -> (batchKey: String, sourceID: SensorKitSourceRecordID) {
            (
                store.sensorKitBatchKey(
                    subject: subject,
                    acquisitionBatch: coordinate,
                    sourceToken: sourceToken,
                    deviceProductType: "iPhone18,1"
                ),
                SensorKitSourceRecordID.derived(
                    acquisitionBatch: coordinate,
                    sourceToken: sourceToken,
                    deviceProductType: "iPhone18,1",
                    recordOrdinal: 0
                )
            )
        }
        let firstZone = try #require(TimeZone(identifier: "Asia/Kathmandu"))
        let abandoned = record(of: "SRSensor.heartRate")
        // Shares the abandoned token as a string prefix, but is a different source.
        let unrelated = record(of: "SRSensor.heartRateSibling")
        for entry in [abandoned, unrelated] {
            try store.verifySensorRetryDigest(Data("first".utf8), batchKey: entry.batchKey, sourceRecordID: entry.sourceID)
            _ = try store.sensorBatchTimeZone(entry.batchKey, current: firstZone)
        }

        try store.abandonSensorBatches(subject: subject, sourceToken: "SRSensor.heartRate")

        try store.verifySensorRetryDigest(Data("changed".utf8), batchKey: abandoned.batchKey, sourceRecordID: abandoned.sourceID)
        #expect(try store.sensorBatchTimeZone(abandoned.batchKey, current: .gmt) == .gmt)
        #expect(throws: FHIRExchangeStateError.retryContentChanged(sourceRecordID: unrelated.sourceID.value)) {
            try store.verifySensorRetryDigest(Data("changed".utf8), batchKey: unrelated.batchKey, sourceRecordID: unrelated.sourceID)
        }
        #expect(try store.sensorBatchTimeZone(unrelated.batchKey, current: .gmt) == firstZone)
    }
}
