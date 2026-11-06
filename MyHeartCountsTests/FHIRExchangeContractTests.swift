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

    /// A participant's accounts in the US and the UK deployments, which one identity secret serves.
    private static var accounts: (unitedStates: FHIRExchangeSubject, unitedKingdom: FHIRExchangeSubject) {
        get throws {
            func account(_ value: String) throws -> FHIRExchangeSubject {
                try FHIRExchangeSubject(identity: BusinessIdentifier(system: FHIRExchangeIdentifiers.participant, value: value))
            }
            return (try account("us-account"), try account("uk-account"))
        }
    }

    private static func facts(study: String? = "study-original") throws -> MyHeartCounts::ConversionFacts {
        MyHeartCounts::ConversionFacts(
            application: try ApplicationDevice(
                name: "My Heart Counts",
                bundleIdentifier: "edu.stanford.MyHeartCounts",
                version: "1",
                build: "1"
            ),
            host: try HostDevice(operatingSystemVersion: "26.0"),
            study: study.map { MyHeartCounts::ConversionFacts.Study(id: $0, revision: 1) }
        )
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
        let firstInstant = Date(timeIntervalSince1970: 1_788_000_100)
        let later = firstInstant.addingTimeInterval(60)
        let firstFacts = FHIRExchangeStateStore.SensorBatchFacts(
            timeZone: firstZone,
            conversionInstant: firstInstant,
            conversionFacts: try .testing(),
            devices: .testing()
        )
        let laterFacts = FHIRExchangeStateStore.SensorBatchFacts(
            timeZone: .gmt,
            conversionInstant: later,
            conversionFacts: try .testing(build: "101", operatingSystem: "27.0", studyRevision: 2),
            devices: .testing(device: UpdatedSensorKitDevice(), sources: [.pinnedPeripheral()])
        )
        #expect(try store.sensorBatchFacts(batchKey, current: firstFacts) == firstFacts)
        try store.verifySensorRetryDigest(Data("first".utf8), batchKey: batchKey, sourceRecordID: sourceID)
        try store.verifySensorRetryDigest(Data("first".utf8), batchKey: batchKey, sourceRecordID: sourceID)
        #expect(throws: FHIRExchangeStateError.retryContentChanged(sourceRecordID: sourceID.value)) {
            try store.verifySensorRetryDigest(Data("changed".utf8), batchKey: batchKey, sourceRecordID: sourceID)
        }
        #expect(try store.sensorBatchFacts(batchKey, current: laterFacts) == firstFacts)

        try store.completeSensorBatch(batchKey)
        try store.verifySensorRetryDigest(Data("changed".utf8), batchKey: batchKey, sourceRecordID: sourceID)
        #expect(try store.sensorBatchFacts(batchKey, current: laterFacts) == laterFacts)
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
        try store.useKnownIdentitySecret()
        let subject = try Self.subject
        let scope = try store.identityScope(subject: subject)
        let root = "https://myheartcounts.stanford.edu/fhir/NamingSystem"
        // `s` and the first 8 characters of the known key's fingerprint for `subject`.
        let keyID = "slH2i51Vw"

        #expect(scope.keyID == keyID)
        #expect(scope.epoch.rawValue == "1")
        let expected: [(IdentifierSystem, String)] = [
            (scope.systems.sourceRecord, "\(root)/grove-source-record-v0/\(keyID)/1"),
            (scope.systems.sourceOutput, "\(root)/grove-source-output-v0/\(keyID)/1"),
            (scope.systems.writerRecord, "\(root)/grove-writer-record-v0/\(keyID)/1"),
            (scope.systems.providerRecord, "\(root)/grove-provider-record-v0/\(keyID)/1"),
            (scope.systems.providerOutput, "\(root)/grove-provider-output-v0/\(keyID)/1"),
            (scope.systems.sourceArtifact, "\(root)/grove-source-artifact-v0/\(keyID)/1"),
            (scope.systems.providerArtifact, "\(root)/grove-provider-artifact-v0/\(keyID)/1"),
            (scope.systems.sourceContext, "\(root)/grove-source-context-v0/\(keyID)/1"),
            (scope.systems.recordingDevice, "\(root)/grove-recording-device-v0/\(keyID)/1"),
            (scope.systems.deviceSnapshot, "\(root)/grove-device-snapshot-v0/\(keyID)/1"),
            (scope.systems.contextSnapshot, "\(root)/grove-context-snapshot-v0/\(keyID)/1"),
            (scope.systems.recordVersion, "\(root)/grove-record-version-v0/\(keyID)/1"),
            (scope.systems.recordRetraction, "\(root)/grove-record-retraction-v0/\(keyID)/1"),
            (scope.systems.deviceLocalIdentifier, "\(root)/grove-device-local-identifier")
        ]
        for (system, literal) in expected {
            #expect(system.rawValue == literal)
        }

        // The system and the value minted under it state the same key id and epoch.
        let record = try scope.sourceRecord(
            adapterID: "healthkit",
            sourceType: "HKQuantityTypeIdentifierStepCount",
            repositoryScope: try store.repositoryScope(.healthKit, subject: subject),
            nativeRecordID: "9512fc92-b514-4bcc-a157-050c41dac51d"
        ).identifier.identifier
        #expect(record.system == scope.systems.sourceRecord)
        #expect(record.value.hasPrefix("v0:\(keyID):1:"))
    }

    /// H11: a participant's US and UK accounts share one secret, but a key id is per subject, so none links the two.
    @Test
    func oneSecretStatesADifferentKeyIDPerSubject() throws {
        let store = FHIRExchangeStateStore()
        try store.useKnownIdentitySecret()
        let accounts = try Self.accounts

        let unitedStates = try store.identityScope(subject: accounts.unitedStates)
        let unitedKingdom = try store.identityScope(subject: accounts.unitedKingdom)

        // Pinned independently of Grove: `s`, then 8 characters of the HMAC of the framed label and subject.
        #expect(unitedStates.keyID == "smvlJazk5")
        #expect(unitedKingdom.keyID == "sXNR5ILxc")
        #expect(unitedStates.systems.sourceRecord != unitedKingdom.systems.sourceRecord)
        #expect(unitedStates.systems.recordVersion != unitedKingdom.systems.recordVersion)

        // The participant's other device, which shares the secret, states the same key id for the same account.
        let otherDevice = FHIRExchangeStateStore(secretsSharedWith: store)
        #expect(try otherDevice.identityScope(subject: accounts.unitedStates).keyID == unitedStates.keyID)
    }

    /// H11: a re-minted key never reuses the key id, and so the systems, of the key it replaces.
    @Test
    func aRemintedKeyStatesANewKeyID() throws {
        let subject = try Self.subject
        let lost = FHIRExchangeStateStore()
        let reminted = FHIRExchangeStateStore()

        let lostScope = try lost.identityScope(subject: subject)
        let remintedScope = try reminted.identityScope(subject: subject)

        #expect(remintedScope.keyID != lostScope.keyID)
        #expect(remintedScope.epoch == lostScope.epoch)
        #expect(remintedScope.systems.sourceRecord != lostScope.systems.sourceRecord)
    }

    /// H11: one sample converted for both accounts under one secret shares no keyed identifier between them, and neither
    /// record states the other account's key id.
    @Test
    func oneSecretKeepsTheRecordsOfTwoSubjectsApart() async throws {
        let harness = ExchangeHarness()
        try harness.identity.useKnownIdentitySecret()
        let accounts = try Self.accounts
        let sample = ExchangeHarness.steps(0)

        let unitedStates = try await #require(
            try harness.exporter(subject: accounts.unitedStates).deliver([sample]).records[sample.uuid]
        )
        let unitedKingdom = try await #require(
            try harness.exporter(subject: accounts.unitedKingdom).deliver([sample]).records[sample.uuid]
        )

        #expect(unitedStates.sourceRecord.system != unitedKingdom.sourceRecord.system)
        #expect(unitedStates.sourceRecord.value != unitedKingdom.sourceRecord.value)
        #expect(unitedStates.version != unitedKingdom.version)
        let unitedStatesKeyID = try harness.identity.identityScope(subject: accounts.unitedStates).keyID
        let unitedKingdomKeyID = try harness.identity.identityScope(subject: accounts.unitedKingdom).keyID
        #expect(String(decoding: unitedStates.json, as: UTF8.self).contains(unitedStatesKeyID))
        #expect(!String(decoding: unitedStates.json, as: UTF8.self).contains(unitedKingdomKeyID))
        #expect(!String(decoding: unitedKingdom.json, as: UTF8.self).contains(unitedStatesKeyID))
    }

    /// A known enrollment travels with its exact protocol revision, and an unenrolled producer names none.
    @Test
    func factsStateTheEnrollmentWithItsProtocolRevision() throws {
        let subject = try Self.subject
        let studyID = "7C1A5E0F-3B2D-4E6A-9F8B-0D1C2E3F4A5B"

        let study = try #require(try Self.facts(study: studyID).studies(for: subject).first)
        let lowercased = "7c1a5e0f-3b2d-4e6a-9f8b-0d1c2e3f4a5b"
        #expect(study.study.value == lowercased)
        #expect(study.protocolURL.value?.url.absoluteString == "https://myheartcounts.stanford.edu/fhir/PlanDefinition/\(lowercased)")
        #expect(study.protocolVersion == "1")
        #expect(study.enrollment.value == "\(lowercased):participant-test")
        #expect(try Self.facts(study: nil).studies(for: subject).isEmpty)
    }

    /// A later layout, and the pre-release layout 0, are refused rather than read.
    @Test(arguments: [0, 2] as [UInt])
    func unsupportedPersistedSchemaFailsClosed(schemaVersion: UInt) throws {
        let store = try FHIRExchangeStateStore(testingSchemaVersion: schemaVersion)
        #expect(throws: FHIRExchangeStateError.unsupportedSchemaVersion(schemaVersion)) {
            try store.verifySensorRetryDigest(
                Data("schema-check".utf8),
                batchKey: "schema-check",
                sourceRecordID: SensorKitSourceRecordID(UUID())
            )
        }
    }

    @Test
    func accountCleanupFencesLateOldGenerationMutations() throws {
        let oldStore = FHIRExchangeStateStore(accountDataGeneration: 7)
        let subject = try Self.subject
        let oldRepository = try oldStore.repositoryScope(.healthKit, subject: subject)
        let sourceID = SensorKitSourceRecordID(UUID())
        try oldStore.verifySensorRetryDigest(Data("account-a".utf8), batchKey: "batch", sourceRecordID: sourceID)
        #expect(oldStore.encodedStateForTesting != nil)

        let newStore = oldStore.testingView(accountDataGeneration: 8)
        try newStore.reset()
        // The scope is store-bound and partitioned by the subject, so the same account keeps
        // its repository across a state reset; a different account gets its own partition.
        let newRepository = try newStore.repositoryScope(.healthKit, subject: subject)
        #expect(newRepository == oldRepository)
        #expect(newStore.encodedStateForTesting != nil)

        #expect(throws: FHIRExchangeStateError.staleAccountGeneration(captured: 7, current: 8)) {
            try oldStore.verifySensorRetryDigest(Data("late".utf8), batchKey: "late-batch", sourceRecordID: sourceID)
        }

        // The reset forgot the previous account's digest, so the new account records its own.
        try newStore.verifySensorRetryDigest(Data("account-b".utf8), batchKey: "batch", sourceRecordID: sourceID)
        try oldStore.completeSensorBatch("batch")
        #expect(throws: FHIRExchangeStateError.retryContentChanged(sourceRecordID: sourceID.value)) {
            try newStore.verifySensorRetryDigest(Data("account-a".utf8), batchKey: "batch", sourceRecordID: sourceID)
        }
    }
}


// MARK: Record Versions

extension FHIRExchangeStateTests {
    /// A record's version follows from its sample, instant, facts, key and subject, and from nothing about its delivery: a
    /// redelivery of one sample of a batch, alone, repeats the version the batch staged for it.
    @Test
    func healthKitRecordVersionsDoNotDependOnTheirBatch() async throws {
        let staging = try await HealthUploadStaging.resolvedForTesting()
        let samples = (0..<3).map(ExchangeHarness.steps)
        try await staging.add(samples, ingestionTimestamp: ExchangeHarness.start)
        let batch = try staging.drainStagedSamples().mapValues(stagedRecordVersion)

        for sample in samples {
            try await staging.add([sample], ingestionTimestamp: ExchangeHarness.start)
            let single = try staging.drainStagedSamples().mapValues(stagedRecordVersion)
            #expect(single == [sample.uuid: try #require(batch[sample.uuid])])
        }
        // Every sample is a source record of its own, with a version of its own.
        #expect(Set(batch.values).count == samples.count)
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
        let firstInstant = Date(timeIntervalSince1970: 1_788_000_100)
        let firstFacts = FHIRExchangeStateStore.SensorBatchFacts(
            timeZone: firstZone,
            conversionInstant: firstInstant,
            conversionFacts: try .testing(),
            devices: .testing()
        )
        let laterFacts = FHIRExchangeStateStore.SensorBatchFacts(
            timeZone: .gmt,
            conversionInstant: firstInstant.addingTimeInterval(60),
            conversionFacts: try .testing(build: "101"),
            devices: .testing(device: UpdatedSensorKitDevice())
        )
        let abandoned = record(of: "SRSensor.heartRate")
        // Shares the abandoned token as a string prefix, but is a different source.
        let unrelated = record(of: "SRSensor.heartRateSibling")
        for entry in [abandoned, unrelated] {
            try store.verifySensorRetryDigest(Data("first".utf8), batchKey: entry.batchKey, sourceRecordID: entry.sourceID)
            _ = try store.sensorBatchFacts(entry.batchKey, current: firstFacts)
        }

        try store.abandonSensorBatches(subject: subject, sourceToken: "SRSensor.heartRate")

        try store.verifySensorRetryDigest(Data("changed".utf8), batchKey: abandoned.batchKey, sourceRecordID: abandoned.sourceID)
        #expect(try store.sensorBatchFacts(abandoned.batchKey, current: laterFacts) == laterFacts)
        #expect(throws: FHIRExchangeStateError.retryContentChanged(sourceRecordID: unrelated.sourceID.value)) {
            try store.verifySensorRetryDigest(Data("changed".utf8), batchKey: unrelated.batchKey, sourceRecordID: unrelated.sourceID)
        }
        #expect(try store.sensorBatchFacts(unrelated.batchKey, current: laterFacts) == firstFacts)
    }
}


// MARK: SensorKit Retry Digests

extension FHIRExchangeStateTests {
    /// Every record of a batch is checked, and its first digests recorded, in one rewrite of the stored state; an
    /// empty batch does not touch it.
    @Test
    func sensorBatchDigestsPersistInOneTransaction() throws {
        let store = FHIRExchangeStateStore()
        let records = (0..<50).map { ordinal in
            FHIRExchangeStateStore.SensorRetryEvidence(
                sourceRecordID: SensorKitSourceRecordID(UUID()),
                evidence: Data("record-\(ordinal)".utf8),
                supplementalEvidence: ordinal.isMultiple(of: 2) ? Data("supplement-\(ordinal)".utf8) : nil
            )
        }

        try store.verifySensorRetryDigests([], batchKey: "batch")
        #expect(store.encodedStateForTesting == nil)
        #expect(store.storageTransactionCountForTesting == 0)
        try store.verifySensorRetryDigests(records, batchKey: "batch")
        #expect(store.storageTransactionCountForTesting == 1)
        try store.verifySensorRetryDigests(records, batchKey: "batch")
        #expect(store.storageTransactionCountForTesting == 2)

        for record in records {
            #expect(throws: FHIRExchangeStateError.retryContentChanged(sourceRecordID: record.sourceRecordID.value)) {
                try store.verifySensorRetryDigest(Data("changed".utf8), batchKey: "batch", sourceRecordID: record.sourceRecordID)
            }
        }
        let supplemented = FHIRExchangeStateStore.SensorRetryEvidence(
            sourceRecordID: records[0].sourceRecordID,
            evidence: records[0].evidence,
            supplementalEvidence: Data("changed".utf8)
        )
        #expect(throws: FHIRExchangeStateError.retryContentChanged(sourceRecordID: supplemented.sourceRecordID.value)) {
            try store.verifySensorRetryDigests([supplemented], batchKey: "batch")
        }
    }

    /// A batch fails on its first drifted record, with the outcome of checking each record alone: the digests first
    /// seen before the drift are recorded, and none after it.
    @Test
    func sensorBatchDriftKeepsTheDigestsFirstSeenBeforeIt() throws {
        let store = FHIRExchangeStateStore()
        let ids = (0..<4).map { _ in SensorKitSourceRecordID(UUID()) }
        for drifting in [ids[1], ids[3]] {
            try store.verifySensorRetryDigest(Data("first".utf8), batchKey: "batch", sourceRecordID: drifting)
        }

        #expect(throws: FHIRExchangeStateError.retryContentChanged(sourceRecordID: ids[1].value)) {
            try store.verifySensorRetryDigests(
                ids.map { .init(sourceRecordID: $0, evidence: Data("changed".utf8)) },
                batchKey: "batch"
            )
        }
        #expect(throws: FHIRExchangeStateError.retryContentChanged(sourceRecordID: ids[0].value)) {
            try store.verifySensorRetryDigest(Data("first".utf8), batchKey: "batch", sourceRecordID: ids[0])
        }
        try store.verifySensorRetryDigest(Data("first".utf8), batchKey: "batch", sourceRecordID: ids[2])
    }
}
