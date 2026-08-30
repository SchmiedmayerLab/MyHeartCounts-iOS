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
import GroveSensorKit
import GroveSensorKitFHIR
import HealthKit
import ModelsR4
@testable import MyHeartCounts
import Testing
// Independent focused suites intentionally share their small FHIR fixtures in this file.
// swiftlint:disable file_types_order

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

    private static let eventFacts = FHIRExchangeEventFacts(
        applicationToken: "edu.stanford.MyHeartCounts",
        applicationName: "My Heart Counts",
        applicationVersion: "1",
        applicationBuild: "1",
        hostToken: "host",
        hostOperatingSystemVersion: "26.0",
        hostName: nil,
        hostManufacturer: "Apple",
        hostModelNumber: nil,
        researchStudyIDs: ["study-original"]
    )

    @Test
    func eventReservationIsStableUntilSourceAcknowledgement() throws { // swiftlint:disable:this function_body_length
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
            facts: Self.eventFacts
        )
        let retry = try store.event(
            key: key,
            recordedAt: Date(timeIntervalSince1970: 1_799_000_000),
            facts: FHIRExchangeEventFacts(
                applicationToken: "changed-on-retry",
                applicationName: "Changed",
                applicationVersion: "2",
                applicationBuild: nil,
                hostToken: "changed-host",
                hostOperatingSystemVersion: "27.0",
                hostName: nil,
                hostManufacturer: nil,
                hostModelNumber: nil,
                researchStudyIDs: ["study-changed-during-retry"]
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
            facts: FHIRExchangeEventFacts(
                applicationToken: "edu.stanford.MyHeartCounts",
                applicationName: "My Heart Counts",
                applicationVersion: "1",
                applicationBuild: "1",
                hostToken: "host",
                hostOperatingSystemVersion: "26.0",
                hostName: nil,
                hostManufacturer: "Apple",
                hostModelNumber: nil,
                researchStudyIDs: ["study-after-completion"]
            )
        )
        #expect(laterPublication.sequence == first.sequence + 1)
        #expect(first.researchStudyIDs == ["study-original"])
        #expect(retry.researchStudyIDs == ["study-original"])
        #expect(laterPublication.researchStudyIDs == ["study-after-completion"])
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
            facts: Self.eventFacts
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
            facts: Self.eventFacts
        )
        #expect(nextEvent.sequence == firstEvent.sequence + 1)
    }

    @Test
    func sensorPublicationDestinationRejectsLogoutAndAccountSwitch() throws {
        let destination = FHIRExchangeDestination(
            accountDataGeneration: 7,
            accountID: "account-a"
        )

        try destination.validate(currentGeneration: 7, cleanupPending: false)
        #expect(destination.accountID == "account-a")
        #expect(throws: FHIRExchangeDestinationError.accountChanged) {
            try destination.validate(currentGeneration: 8, cleanupPending: false)
        }
        #expect(throws: FHIRExchangeDestinationError.accountChanged) {
            try destination.validate(currentGeneration: 7, cleanupPending: true)
        }
    }

    @Test
    func questionnaireSubmissionRejectsAccountSwitchWithoutRetargeting() throws {
        let subject = try FHIRExchangeSubject(identity: BusinessIdentifier(
            system: FHIRExchangeIdentifiers.participant,
            value: "participant-a"
        ))
        let submission = QuestionnaireSubmissionContext(
            subject: subject,
            destination: FHIRExchangeDestination(
                accountDataGeneration: 11,
                accountID: "account-a"
            )
        )

        #expect(submission.subject.identity.value == "participant-a")
        #expect(submission.destination.accountID == "account-a")
        #expect(throws: FHIRExchangeDestinationError.accountChanged) {
            try submission.destination.validate(currentGeneration: 12, cleanupPending: false)
        }
        #expect(submission.destination.accountID == "account-a")
    }

    @Test
    func sourceRepositoriesAreInstallationScopedAndDistinct() throws {
        let store = FHIRExchangeStateStore()
        let health = try store.repositoryScope(.healthKit)
        let sensor = try store.repositoryScope(.sensorKit)
        let repeatedHealth = try store.repositoryScope(.healthKit)
        #expect(health != sensor)
        #expect(health == repeatedHealth)
        #expect(health.value.hasPrefix("healthkit:"))
        #expect(sensor.value.hasPrefix("sensorkit:"))
    }

    @Test
    func pseudonymousSystemsBindRoleProtocolGenerationAndKeyEpoch() throws {
        let systems = try FHIRExchangeIdentifiers.pseudonymousSystems
        let values = [
            systems.sourceRecord,
            systems.sourceOutput,
            systems.writerRecord,
            systems.providerRecord,
            systems.providerOutput,
            systems.sourceArtifact,
            systems.providerArtifact,
            systems.sourceContext,
            systems.recordingDevice,
            systems.deviceSnapshot
        ].map(\.rawValue)

        #expect(Set(values).count == values.count)
        #expect(values.allSatisfy { $0.contains("-v0/installation/1") })
    }

    @Test
    func unsupportedPersistedSchemaFailsClosed() throws {
        let store = FHIRExchangeStateStore(testingSchemaVersion: 1)
        #expect(throws: FHIRExchangeStateError.unsupportedSchemaVersion(1)) {
            try store.repositoryScope(.healthKit)
        }
    }

    @Test
    func accountCleanupFencesLateOldGenerationMutations() throws {
        let oldStore = FHIRExchangeStateStore(accountDataGeneration: 7)
        let oldRepository = try oldStore.repositoryScope(.healthKit)
        let subject = try Self.subject
        let eventKey = oldStore.healthKitEventKey(
            subject: subject,
            sourceType: "HKQuantityTypeIdentifierStepCount",
            nativeRecordID: UUID()
        )
        _ = try oldStore.event(
            key: eventKey,
            recordedAt: Date(timeIntervalSince1970: 1_788_000_000),
            facts: Self.eventFacts
        )
        let oldStateWasPersisted = try oldStore.hasPersistedStateForTesting
        #expect(oldStateWasPersisted)

        let newStore = oldStore.testingView(accountDataGeneration: 8)
        try newStore.reset()
        let newRepository = try newStore.repositoryScope(.healthKit)
        let newStateWasPersisted = try newStore.hasPersistedStateForTesting
        #expect(newRepository != oldRepository)
        #expect(newStateWasPersisted)

        #expect(throws: FHIRExchangeStateError.staleAccountGeneration(captured: 7, current: 8)) {
            _ = try oldStore.event(
                key: "late-old-account-reservation",
                recordedAt: Date(timeIntervalSince1970: 1_788_000_001),
                facts: Self.eventFacts
            )
        }

        let newEvent = try newStore.event(
            key: eventKey,
            recordedAt: Date(timeIntervalSince1970: 1_788_000_002),
            facts: Self.eventFacts
        )
        try oldStore.completeHealthKitEvent(eventKey)
        try oldStore.completeSensorBatch("late-account-a-batch")
        let retry = try newStore.event(
            key: eventKey,
            recordedAt: Date(timeIntervalSince1970: 1_799_000_000),
            facts: Self.eventFacts
        )
        #expect(retry == newEvent)
    }
}

@Suite
struct QuestionnaireHealthKitProjectionTests {
    @Test
    func bloodPressureBuildsOneCorrelationWithTwoComponents() throws {
        let responseJSON = Data(#"""
        {
          "resourceType":"QuestionnaireResponse",
          "status":"completed",
          "authored":"2026-08-29T12:00:00-07:00",
          "item":[
            {"linkId":"systolic","answer":[{"valueQuantity":{"value":118,"system":"http://unitsofmeasure.org","code":"mm[Hg]"}}]},
            {"linkId":"diastolic","answer":[{"valueQuantity":{"value":76,"system":"http://unitsofmeasure.org","code":"mm[Hg]"}}]}
          ]
        }
        """#.utf8)
        let response = try JSONDecoder().decode(QuestionnaireResponse.self, from: responseJSON)
        let correlation = try #require(try QuestionnaireDataExtractor(response: response).bloodPressureCorrelation(
            systolicLinkID: "systolic",
            diastolicLinkID: "diastolic"
        ))
        #expect(correlation.objects.count == 2)
        #expect(correlation.objects.allSatisfy { $0 is HKQuantitySample })
    }

    @Test
    func bloodPressureUsesSiblingAnswersWithinOneGroupOccurrence() throws {
        let responseJSON = Data(#"""
        {
          "resourceType":"QuestionnaireResponse",
          "status":"completed",
          "authored":"2026-08-29T12:00:00-07:00",
          "item":[{
            "linkId":"blood-pressure",
            "item":[
              {"linkId":"systolic","answer":[{"valueQuantity":{"value":118,"system":"http://unitsofmeasure.org","code":"mm[Hg]"}}]},
              {"linkId":"diastolic","answer":[{"valueQuantity":{"value":76,"system":"http://unitsofmeasure.org","code":"mm[Hg]"}}]}
            ]
          }]
        }
        """#.utf8)
        let response = try JSONDecoder().decode(QuestionnaireResponse.self, from: responseJSON)
        let correlation = try #require(try QuestionnaireDataExtractor(response: response).bloodPressureCorrelation(
            systolicLinkID: "systolic",
            diastolicLinkID: "diastolic"
        ))

        #expect(correlation.objects.count == 2)
    }

    @Test
    func bloodPressureRejectsAnswersFromDifferentGroups() throws {
        let responseJSON = Data(#"""
        {
          "resourceType":"QuestionnaireResponse",
          "status":"completed",
          "authored":"2026-08-29T12:00:00-07:00",
          "item":[
            {"linkId":"first-group","item":[
              {"linkId":"systolic","answer":[{"valueQuantity":{"value":118,"system":"http://unitsofmeasure.org","code":"mm[Hg]"}}]}
            ]},
            {"linkId":"second-group","item":[
              {"linkId":"diastolic","answer":[{"valueQuantity":{"value":76,"system":"http://unitsofmeasure.org","code":"mm[Hg]"}}]}
            ]}
          ]
        }
        """#.utf8)
        let response = try JSONDecoder().decode(QuestionnaireResponse.self, from: responseJSON)

        #expect(throws: QuestionnaireDataExtractionError.uncorrelatedBloodPressure(
            systolicLinkID: "systolic",
            diastolicLinkID: "diastolic"
        )) {
            _ = try QuestionnaireDataExtractor(response: response).bloodPressureCorrelation(
                systolicLinkID: "systolic",
                diastolicLinkID: "diastolic"
            )
        }
    }

    @Test
    func bloodPressureRejectsMultipleRepeatingGroupOccurrences() throws {
        let responseJSON = Data(#"""
        {
          "resourceType":"QuestionnaireResponse",
          "status":"completed",
          "authored":"2026-08-29T12:00:00-07:00",
          "item":[
            {"linkId":"blood-pressure","item":[
              {"linkId":"systolic","answer":[{"valueQuantity":{"value":118,"system":"http://unitsofmeasure.org","code":"mm[Hg]"}}]},
              {"linkId":"diastolic","answer":[{"valueQuantity":{"value":76,"system":"http://unitsofmeasure.org","code":"mm[Hg]"}}]}
            ]},
            {"linkId":"blood-pressure","item":[
              {"linkId":"systolic","answer":[{"valueQuantity":{"value":121,"system":"http://unitsofmeasure.org","code":"mm[Hg]"}}]},
              {"linkId":"diastolic","answer":[{"valueQuantity":{"value":79,"system":"http://unitsofmeasure.org","code":"mm[Hg]"}}]}
            ]}
          ]
        }
        """#.utf8)
        let response = try JSONDecoder().decode(QuestionnaireResponse.self, from: responseJSON)

        #expect(throws: QuestionnaireDataExtractionError.ambiguousBloodPressure(
            systolicLinkID: "systolic",
            diastolicLinkID: "diastolic"
        )) {
            _ = try QuestionnaireDataExtractor(response: response).bloodPressureCorrelation(
                systolicLinkID: "systolic",
                diastolicLinkID: "diastolic"
            )
        }
    }

    @Test
    func codedQuantityRequiresUCUMForHealthKitProjection() throws {
        let responseJSON = Data(#"""
        {
          "resourceType":"QuestionnaireResponse",
          "status":"completed",
          "authored":"2026-08-29T12:00:00-07:00",
          "item":[{
            "linkId":"weight",
            "answer":[{"valueQuantity":{"value":70,"system":"https://example.org/units","code":"kg"}}]
          }]
        }
        """#.utf8)
        let response = try JSONDecoder().decode(QuestionnaireResponse.self, from: responseJSON)

        #expect(throws: QuestionnaireDataExtractionError.unsupportedQuantitySystem(
            linkID: "weight",
            system: "https://example.org/units"
        )) {
            _ = try QuestionnaireDataExtractor(response: response).quantitySample(
                SampleType<HKQuantitySample>.bodyMass,
                linkID: "weight"
            )
        }
    }
}
