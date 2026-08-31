//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFHIRContract
import GroveHealthKitFHIR
import GroveQuestionnaireFHIR
import HealthKit
import ModelsR4
@testable import MyHeartCounts
import Synchronization
import Testing


@Suite
struct FHIRExchangeIdentityScopeTests {
    private static var subject: FHIRExchangeSubject {
        get throws {
            FHIRExchangeSubject(identity: try BusinessIdentifier(
                system: FHIRExchangeIdentifiers.participant,
                value: "participant-1"
            ))
        }
    }

    @Test
    func identitySecretIsMintedOnceAndSurvivesAccountReset() throws {
        let store = FHIRExchangeStateStore(accountDataGeneration: 1)
        let secret = try store.identitySecret()
        #expect(secret.key.count == 32)
        #expect(try store.identitySecret() == secret)

        let afterReset = store.testingView(accountDataGeneration: 2)
        try afterReset.reset()
        #expect(try afterReset.identitySecret() == secret)
    }

    @Test
    func repositoryScopePartitionsPerAccount() throws {
        let store = FHIRExchangeStateStore()
        let accountA = FHIRExchangeSubject(identity: try BusinessIdentifier(
            system: FHIRExchangeIdentifiers.participant,
            value: "account-a"
        ))
        let accountB = FHIRExchangeSubject(identity: try BusinessIdentifier(
            system: FHIRExchangeIdentifiers.participant,
            value: "account-b"
        ))
        let scopeA = try store.repositoryScope(.healthKit, subject: accountA)
        #expect(scopeA == (try store.repositoryScope(.healthKit, subject: accountA)))
        #expect(scopeA != (try store.repositoryScope(.healthKit, subject: accountB)))
        #expect(scopeA != (try store.repositoryScope(.questionnaire, subject: accountA)))
    }

    /// The exact identifier a known secret mints, so no part of the app-owned composition —
    /// repository-scope format, adapter and source-type strings, or the secret's own decoding —
    /// can change without re-identifying every record already exported.
    @Test
    func appOwnedIdentityCompositionIsPinned() throws {
        let store = FHIRExchangeStateStore()
        guard case .memory(let secrets) = store.secrets else {
            Issue.record("An in-memory store must carry an in-memory secret backend")
            return
        }
        secrets.secret.withLock { stored in
            stored = try? JSONDecoder().decode(FHIRExchangeIdentitySecret.self, from: Data("""
                {
                  "key": "AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA=",
                  "storeID": "3F8A1D2E-4B5C-6D7E-8F90-A1B2C3D4E5F6",
                  "epoch": 1
                }
            """.utf8))
        }
        let scope = try store.repositoryScope(.healthKit, subject: try Self.subject)
        #expect(scope.systemValue == "https://myheartcounts.stanford.edu/fhir/identifiers/repository")
        #expect(scope.value == "healthkit:3f8a1d2e-4b5c-6d7e-8f90-a1b2c3d4e5f6:participant-1")

        let identity = try store.identityScope().sourceRecord(
            adapterID: "healthkit",
            sourceType: "HKQuantityTypeIdentifierStepCount",
            repositoryScope: scope,
            nativeRecordID: "9512fc92-b514-4bcc-a157-050c41dac51d"
        )
        #expect(identity.value == "v0:store:1:3_vdE_qomxipxpR-C7cSNp4tlxgrHrMUx9A-hYVz0n0")
    }

    @Test
    func sharedSecretMintsIdenticalIdentitiesAcrossDevices() throws {
        let deviceOne = FHIRExchangeStateStore()
        let deviceTwo = FHIRExchangeStateStore(secretsSharedWith: deviceOne)
        let subject = try Self.subject

        let scopeOne = try deviceOne.repositoryScope(.healthKit, subject: subject)
        let scopeTwo = try deviceTwo.repositoryScope(.healthKit, subject: subject)
        #expect(scopeOne == scopeTwo)

        let recordOne = try deviceOne.identityScope().sourceRecord(
            adapterID: "healthkit",
            sourceType: "HKQuantityTypeIdentifierStepCount",
            repositoryScope: scopeOne,
            nativeRecordID: "ABC"
        )
        let recordTwo = try deviceTwo.identityScope().sourceRecord(
            adapterID: "healthkit",
            sourceType: "HKQuantityTypeIdentifierStepCount",
            repositoryScope: scopeTwo,
            nativeRecordID: "ABC"
        )
        #expect(recordOne == recordTwo)
        #expect(recordOne.value.hasPrefix("v0:store:1:"))
    }
}


@Suite
struct QuestionnaireHealthKitProjectionTests {
    /// A minimal marked instrument: the panel's children are components by declaration, so a
    /// projection can never pair answers across groups — the structural guarantee the old
    /// extractor enforced by matching group occurrences.
    private static let instrumentJSON = Data("""
        {
          "resourceType": "Questionnaire",
          "url": "https://myheartcounts.stanford.edu/fhir/survey/heartRisk",
          "version": "1.0.0",
          "status": "active",
          "item": [{
            "linkId": "bp",
            "type": "group",
            "code": [{"system": "http://loinc.org", "code": "85354-9"}],
            "extension": [{
              "url": "http://hl7.org/fhir/uv/sdc/StructureDefinition/sdc-questionnaire-observationExtract",
              "valueBoolean": true
            }],
            "item": [
              {
                "linkId": "systolic",
                "type": "quantity",
                "code": [{"system": "http://loinc.org", "code": "8480-6"}],
                "extension": [{
                  "url": "http://hl7.org/fhir/uv/sdc/StructureDefinition/sdc-questionnaire-observationExtract",
                  "valueCode": "component"
                }]
              },
              {
                "linkId": "diastolic",
                "type": "quantity",
                "code": [{"system": "http://loinc.org", "code": "8462-4"}],
                "extension": [{
                  "url": "http://hl7.org/fhir/uv/sdc/StructureDefinition/sdc-questionnaire-observationExtract",
                  "valueCode": "component"
                }]
              }
            ]
          }, {
            "linkId": "bone",
            "type": "quantity",
            "code": [{"system": "http://loinc.org", "code": "101685-6"}],
            "extension": [{
              "url": "http://hl7.org/fhir/uv/sdc/StructureDefinition/sdc-questionnaire-observationExtract",
              "valueBoolean": true
            }]
          }]
        }
    """.utf8)

    private static func responseJSON(systolic: Double, diastolic: Double?) -> Data {
        var answers = """
            {
              "linkId": "systolic",
              "answer": [{"valueQuantity": {
                "value": \(systolic), "unit": "mmHg",
                "system": "http://unitsofmeasure.org", "code": "mm[Hg]"
              }}]
            }
        """
        if let diastolic {
            answers += """
            , {
              "linkId": "diastolic",
              "answer": [{"valueQuantity": {
                "value": \(diastolic), "unit": "mmHg",
                "system": "http://unitsofmeasure.org", "code": "mm[Hg]"
              }}]
            }
            """
        }
        return Data("""
        {
          "resourceType": "QuestionnaireResponse",
          "meta": {"profile": ["https://grovealliance.org/fhir/questionnaire/StructureDefinition/grove-questionnaire-response"]},
          "questionnaire": "https://myheartcounts.stanford.edu/fhir/survey/heartRisk|1.0.0",
          "status": "completed",
          "authored": "2026-08-29T12:00:00-07:00",
          "identifier": {"system": "https://myheartcounts.stanford.edu/fhir/identifiers/response", "value": "response-1"},
          "subject": {"reference": "Patient/participant"},
          "item": [
            {"linkId": "bp", "item": [\(answers)]},
            {"linkId": "bone", "answer": [{"valueQuantity": {
              "value": 30, "unit": "kg",
              "system": "http://unitsofmeasure.org", "code": "kg"
            }}]}
          ]
        }
        """.utf8)
    }

    private static func pair(
        systolic: Double = 118,
        diastolic: Double? = 76
    ) throws -> (Questionnaire, QuestionnaireResponse) {
        (
            try JSONDecoder().decode(Questionnaire.self, from: instrumentJSON),
            try JSONDecoder().decode(QuestionnaireResponse.self, from: responseJSON(systolic: systolic, diastolic: diastolic))
        )
    }

    /// The projection production runs, so a test can never exercise different semantics.
    private static func samples(
        questionnaire: Questionnaire,
        response: QuestionnaireResponse,
        store: FHIRExchangeStateStore = FHIRExchangeStateStore(),
        onRefusal: (any Error) -> Void = { _ in }
    ) throws -> [HKSample] {
        var response = response
        response.apply(writerContext: try .current(
            applicationIdentifierSystem: FHIRExchangeIdentifiers.application
        ))
        let reservation = try store.questionnaireConversion(
            responseID: "response-1",
            subject: FHIRExchangeSubject(identity: try BusinessIdentifier(
                system: FHIRExchangeIdentifiers.participant,
                value: "participant-1"
            )),
            conversionInstant: Date(timeIntervalSince1970: 1_787_000_000)
        )
        let graph = try QuestionnaireExchangeProjection.exchangeGraph(
            questionnaire: questionnaire,
            response: response,
            context: reservation.context
        )
        return HealthKitSampleProjection.samples(in: graph, onRefusal: onRefusal)
    }

    @Test
    func bloodPressureBuildsOneCorrelationWithTwoComponents() throws {
        let (questionnaire, response) = try Self.pair()
        let store = FHIRExchangeStateStore()
        let samples = try Self.samples(questionnaire: questionnaire, response: response, store: store)
        let correlation = try #require(samples.compactMap { $0 as? HKCorrelation }.first)
        #expect(correlation.correlationType == HKCorrelationType(.bloodPressure))
        // Asserted per component type: an unordered value set cannot tell a swap from a match.
        func value(of type: HKQuantityTypeIdentifier) -> Double? {
            correlation.objects
                .compactMap { $0 as? HKQuantitySample }
                .first { $0.quantityType == HKQuantityType(type) }?
                .quantity.doubleValue(for: .millimeterOfMercury())
        }
        #expect(value(of: .bloodPressureSystolic) == 118)
        #expect(value(of: .bloodPressureDiastolic) == 76)
        #expect(correlation.objects.count == 2)
        #expect(correlation.metadata?[HKMetadataKeyWasUserEntered] as? Bool == true)

        // The sync identity is the minted source-output identity: deterministic, so the same
        // response re-projected through the same store replaces its earlier samples.
        let syncID = try #require(correlation.metadata?[HKMetadataKeySyncIdentifier] as? String)
        #expect(syncID.hasPrefix("v0:store:1:"))
        let again = try Self.samples(questionnaire: questionnaire, response: response, store: store)
        let repeated = try #require(again.compactMap { $0 as? HKCorrelation }.first)
        #expect(repeated.metadata?[HKMetadataKeySyncIdentifier] as? String == syncID)
    }

    @Test
    func bloodPressureRefusesAnIncompleteComponentSet() throws {
        let (questionnaire, response) = try Self.pair(diastolic: nil)
        #expect(throws: ObservationExtractionError.answerMissing(linkID: "diastolic")) {
            _ = try Self.samples(questionnaire: questionnaire, response: response)
        }
    }

    /// Bone mass extracts but has no HealthKit type to land on, so it is the reading that is lost.
    @Test
    func oneUnprojectableMeasurementStillYieldsTheOthers() throws {
        let (questionnaire, response) = try Self.pair()
        var refusals: [any Error] = []
        let samples = try Self.samples(
            questionnaire: questionnaire,
            response: response,
            onRefusal: { refusals.append($0) }
        )
        #expect(samples.compactMap { $0 as? HKCorrelation }.count == 1)
        #expect(refusals.count == 1)
        #expect(
            refusals.first as? HealthKitSampleProjectionError
                == .measurementNotMappable(id: "bone-mass")
        )
    }

    @Test
    func unmarkedItemsNeverProject() throws {
        var (questionnaire, response) = try Self.pair()
        questionnaire.item?[0].extension = nil
        questionnaire.item?[1].extension = nil
        // A survey that measures nothing refuses before any identity is minted, so nothing
        // reaches HealthKit and no exchange event is spent on it.
        #expect(throws: ObservationExtractionError.noExtractableMeasurements) {
            _ = try Self.samples(questionnaire: questionnaire, response: response)
        }
    }
}
