//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFHIRContract
import GroveHealthKitFHIR
import HealthKit
import ModelsR4
@testable import MyHeartCounts
import Testing


/// Deletions ship as Grove Mobile retraction records minted from the same identity scope as the
/// additions they retract, so both halves of a record's lifecycle speak one identity language.
@Suite
struct HealthKitRetractionTests {
    /// One retraction target reduced to the facts a receiver resolves it by.
    private struct DescribedTarget: Hashable {
        let identifier: String
        let system: String
        let resourceType: String?
        let role: String?
    }

    private static let detectedAt = Date(timeIntervalSince1970: 1_788_000_000)
    private static let recordedAt = Date(timeIntervalSince1970: 1_788_000_060)

    private static var subject: FHIRExchangeSubject {
        get throws {
            try FHIRExchangeSubject(identity: BusinessIdentifier(
                system: FHIRExchangeIdentifiers.participant,
                value: "participant-1"
            ))
        }
    }

    private static func record(
        sourceType: String = "HKQuantityTypeIdentifierStepCount",
        deletedAfter: Date? = nil
    ) throws -> HealthKitDeletedRecord {
        HealthKitDeletedRecord(
            sourceTypeIdentifier: sourceType,
            nativeRecordID: try #require(UUID(uuidString: "9512FC92-B514-4BCC-A157-050C41DAC51D")),
            deletedAfter: deletedAfter,
            detectedAt: detectedAt
        )
    }

    private static func provenance(in record: ExchangeRecord) throws -> Provenance {
        let graph = try ExchangeGraph(validating: record.json, kind: .retraction)
        let provenances = (graph.bundle.entry ?? []).compactMap { entry -> Provenance? in
            guard case .provenance(let provenance) = entry.resource else {
                return nil
            }
            return provenance
        }
        #expect(provenances.count == 1, "A retraction record carries exactly one Provenance")
        return try #require(provenances.first)
    }

    private static func targets(in record: ExchangeRecord) throws -> [DescribedTarget] {
        try provenance(in: record).target.map { target in
            DescribedTarget(
                identifier: target.identifier?.value?.value?.string ?? "",
                system: target.identifier?.system?.value?.url.absoluteString ?? "",
                resourceType: target.type?.value?.url.absoluteString,
                role: target.extension?.compactMap { role -> String? in
                    guard role.url.value?.url.absoluteString
                        == Canonicals.retractionTargetRole.value?.url.absoluteString,
                        case .code(let code)? = role.value else {
                        return nil
                    }
                    return code.value?.string
                }.first
            )
        }
    }

    /// The native record identifier `target` carries, as a typed Identifier.
    private static func nativeIdentifier(of target: Reference) throws -> Identifier {
        let native = try #require(target.extension?.first { extensionValue in
            extensionValue.url.value?.url.absoluteString == Canonicals.retractionTargetNativeIdentifier.value?.url.absoluteString
        })
        guard case .identifier(let identifier)? = native.value else {
            Issue.record("The native record identifier travels as a typed Identifier")
            throw CancellationError()
        }
        return identifier
    }

    private static func sourceRecord(
        of record: HealthKitDeletedRecord,
        in store: FHIRExchangeStateStore,
        subject: FHIRExchangeSubject
    ) throws -> SourceRecordIdentity {
        try store.identityScope(subject: subject).sourceRecord(
            adapterID: "healthkit",
            sourceType: record.sourceTypeIdentifier,
            repositoryScope: try store.repositoryScope(.healthKit, subject: subject),
            nativeRecordID: record.nativeRecordID.uuidString.lowercased()
        )
    }

    private static func retraction(
        of record: HealthKitDeletedRecord,
        in store: FHIRExchangeStateStore,
        subject: FHIRExchangeSubject,
        recordedAt: Date = Self.recordedAt
    ) async throws -> ExchangeRecord {
        guard case .record(let retraction) = try await store.retraction(of: record, subject: subject, recordedAt: recordedAt) else {
            Issue.record("The deletion has something to retract, and nothing to refuse")
            throw CancellationError()
        }
        return retraction
    }

    /// H7: a retraction's one target is the source record, which the addition's own coordinates mint.
    @Test
    func retractionNamesTheSameIdentitiesTheAdditionMinted() async throws {
        let store = FHIRExchangeStateStore()
        let subject = try Self.subject
        let record = try Self.record()
        let retraction = try await Self.retraction(of: record, in: store, subject: subject)
        let expectedSourceRecord = try Self.sourceRecord(of: record, in: store, subject: subject)

        #expect(retraction.kind == .retraction)
        #expect(retraction.sourceRecord == expectedSourceRecord.identifier.identifier)
        #expect(retraction.outputFullURLs.isEmpty)
        #expect(
            try Self.provenance(in: retraction).entity?.first?.what.identifier?.value?.value?.string
                == expectedSourceRecord.identifier.identifier.value
        )
        try Self.validateSourceRecordRetraction(retraction, of: record, in: store, subject: subject)
    }

    /// Decision 8, H14: the HealthKit UUID reaches the wire as the target's native identifier, lowercase, and in no other way.
    @Test
    func retractionTargetCarriesTheLowercasedNativeRecordIdentifier() async throws {
        let store = FHIRExchangeStateStore()
        let retraction = try await Self.retraction(of: try Self.record(), in: store, subject: try Self.subject)
        let target = try #require(try Self.provenance(in: retraction).target.first)
        let identifier = try Self.nativeIdentifier(of: target)

        #expect(identifier.value?.value?.string == "9512fc92-b514-4bcc-a157-050c41dac51d")
        #expect(identifier.system?.value?.url.absoluteString == FHIRExchangeIdentifiers.healthKitNativeRecord.rawValue)
        let json = String(decoding: retraction.json, as: UTF8.self).lowercased()
        #expect(json.components(separatedBy: "9512fc92-b514-4bcc-a157-050c41dac51d").count == 2)
    }

    /// A workout deletion names the source record so it covers the session and every event/activity segment.
    @Test
    func deletedWorkoutRetractsItsSourceRecord() async throws {
        let store = FHIRExchangeStateStore()
        let subject = try Self.subject
        let record = try Self.record(sourceType: HKWorkoutType.workoutType().identifier)
        let retraction = try await Self.retraction(of: record, in: store, subject: subject)
        try Self.validateSourceRecordRetraction(retraction, of: record, in: store, subject: subject)
    }

    /// Clinical records and CDA documents are platform-exclusive rows carrying no measurement, yet every one of them
    /// leaves as a `clinical-record` DocumentReference, which its source record covers.
    @Test(arguments: [
        "HKClinicalTypeIdentifierLabResultRecord",
        "HKClinicalTypeIdentifierMedicationRecord",
        "HKClinicalTypeIdentifierVitalSignRecord",
        "HKDocumentTypeIdentifierCDA"
    ])
    func deletedClinicalDocumentRetractsItsSourceRecord(sourceType: String) async throws {
        let store = FHIRExchangeStateStore()
        let subject = try Self.subject
        let record = try Self.record(sourceType: sourceType)
        let retraction = try await Self.retraction(of: record, in: store, subject: subject)
        try Self.validateSourceRecordRetraction(retraction, of: record, in: store, subject: subject)
    }

    /// An ECG deletion covers the waveform and an optional average-heart-rate child whose presence it cannot know.
    @Test
    func deletedElectrocardiogramRetractsItsSourceRecord() async throws {
        let store = FHIRExchangeStateStore()
        let subject = try Self.subject
        let record = try Self.record(sourceType: HKObjectType.electrocardiogramType().identifier)
        let retraction = try await Self.retraction(of: record, in: store, subject: subject)
        try Self.validateSourceRecordRetraction(retraction, of: record, in: store, subject: subject)
    }

    /// A record class Grove never exports, or does not inventory at all, has nothing to retract.
    @Test(arguments: [
        "HKVisionPrescriptionTypeIdentifier",
        "HKDataTypeIdentifierAudiogram",
        "HKCorrelationTypeIdentifierFood",
        "HKQuantityTypeIdentifierBloodPressureSystolic",
        "HKCharacteristicTypeIdentifierBloodType",
        "HKQuantityTypeIdentifierNotInTheInventory"
    ])
    func unexportedSourceTypesMintNoRetraction(sourceType: String) async throws {
        let outcome = try await FHIRExchangeStateStore().retraction(
            of: try Self.record(sourceType: sourceType),
            subject: try Self.subject,
            recordedAt: Self.recordedAt
        )

        guard case .nothingToRetract = outcome else {
            Issue.record("A record class Grove never exports has nothing to retract")
            return
        }
    }

    /// The end-to-end agreement the two halves of one record's lifecycle owe each other.
    @Test
    func retractionNamesTheSourceRecordTheConverterActuallyMinted() async throws {
        let store = FHIRExchangeStateStore()
        let subject = try Self.subject
        let sample = HKQuantitySample(
            type: HKQuantityType(.stepCount),
            quantity: HKQuantity(unit: .count(), doubleValue: 42),
            start: Self.detectedAt - 3600,
            end: Self.detectedAt - 3540
        )
        let delivery = try await ExchangeHarness(identity: store).exporter(subject: subject).deliver([sample], at: Self.detectedAt - 3000)
        let conversion = try #require(delivery.records[sample.uuid])
        let retraction = try await Self.retraction(
            of: HealthKitDeletedRecord(
                sourceTypeIdentifier: sample.sampleType.identifier,
                nativeRecordID: sample.uuid,
                deletedAfter: nil,
                detectedAt: Self.detectedAt
            ),
            in: store,
            subject: subject
        )

        #expect(try Self.targets(in: retraction).map(\.identifier) == [conversion.sourceRecord.value])
        #expect(retraction.sourceRecord == conversion.sourceRecord)
        // Decision 8: every copy of a sample states its HealthKit UUID, so whoever ingests them can dedupe them by it.
        let target = try #require(try Self.provenance(in: retraction).target.first)
        #expect(try Self.nativeIdentifier(of: target).value?.value?.string == nativeRecordIdentifier(of: conversion))
    }

    /// HealthKit states no deletion time. Preserve its bounds without claiming an exact instant,
    /// including when an old anchor or a backwards clock adjustment leaves no valid lower bound.
    @Test(arguments: [
        (nil, nil),
        (Self.detectedAt - 3600, Self.detectedAt - 3600),
        (Self.detectedAt, Self.detectedAt),
        (Self.detectedAt + 3600, nil)
    ] as [(Date?, Date?)])
    func retractionPreservesDeletionBounds(deletedAfter: Date?, expectedStart: Date?) async throws {
        let store = FHIRExchangeStateStore()
        let record = try Self.record(deletedAfter: deletedAfter)
        let retraction = try await Self.retraction(of: record, in: store, subject: try Self.subject)
        let provenance = try Self.provenance(in: retraction)
        guard case .period(let occurred)? = provenance.occurred else {
            Issue.record("A detected deletion carries the known bounds on its occurrence")
            return
        }

        #expect(try occurred.start?.value?.asNSDate() == expectedStart)
        #expect(try occurred.end?.value?.asNSDate() == Self.detectedAt)
        #expect(try provenance.recorded.value?.asNSDate() == Self.recordedAt)
        // H14: the HealthKit UUID is never `Bundle.id` or `Bundle.identifier`.
        let bundle = try ExchangeGraph(validating: retraction.json, kind: .retraction).bundle
        #expect(bundle.id == nil)
        #expect(bundle.identifier == nil)
    }
}


extension HealthKitRetractionTests {
    /// A retraction's key is a function of the source record alone, so a re-drain repeats it and the first accepted wins.
    /// Nothing is kept between the two attempts: the retry states the deletion's bounds again, and its own conversion time.
    @Test
    func retryingARetractionRepeatsItsKeyAndBounds() async throws {
        let store = FHIRExchangeStateStore()
        let subject = try Self.subject
        let record = try Self.record(deletedAfter: Self.detectedAt - 3600)
        let first = try await Self.retraction(of: record, in: store, subject: subject)
        let retry = try await Self.retraction(of: record, in: store, subject: subject, recordedAt: Self.recordedAt + 3600)

        #expect(retry.version == first.version)
        #expect(retry.version.identifier.role == .recordRetraction)
        #expect(retry.sourceRecord == first.sourceRecord)
        #expect(try Self.provenance(in: retry).occurred == Self.provenance(in: first).occurred)
        #expect(try Self.provenance(in: retry).recorded.value?.asNSDate() == Self.recordedAt + 3600)
    }
}


extension FHIRExchangeStateStore {
    /// The outcome of retracting one deleted record, as the drain retracts a chunk of one.
    fileprivate func retraction(
        of record: HealthKitDeletedRecord,
        subject: FHIRExchangeSubject,
        recordedAt: Date
    ) async throws -> HealthKitFHIRExporter.Retraction.Outcome {
        try await healthKitExporter(subject: subject, facts: .testing()).healthKitRetractions(of: [record], recordedAt: recordedAt)[0]
    }
}


/// The native record identifier the conversion states on its primary Observation.
private func nativeRecordIdentifier(of conversion: ExchangeRecord) throws -> String {
    let graph = try ExchangeGraph(validating: conversion.json, kind: .active)
    let nativeSystem = FHIRExchangeIdentifiers.healthKitNativeRecord.rawValue
    return try #require(graph.bundle.entry?.lazy.compactMap { entry -> String? in
        guard case .observation(let observation)? = entry.resource else {
            return nil
        }
        return observation.identifier?.first { $0.system?.value?.url.absoluteString == nativeSystem }?.value?.value?.string
    }.first)
}


extension HealthKitRetractionTests {
    /// Every output of a record, a conditional child included, is retracted through its source record, without inventing
    /// output identities.
    private static func validateSourceRecordRetraction(
        _ retraction: ExchangeRecord,
        of record: HealthKitDeletedRecord,
        in store: FHIRExchangeStateStore,
        subject: FHIRExchangeSubject
    ) throws {
        let source = try sourceRecord(of: record, in: store, subject: subject).identifier.identifier
        let expected = DescribedTarget(
            identifier: source.value,
            system: source.system.rawValue,
            resourceType: nil,
            role: "source-record"
        )
        #expect(try targets(in: retraction) == [expected])
        let target = try #require(try provenance(in: retraction).target.first)
        #expect(target.type == nil, "A source record is not a FHIR resource type")
        let identifier = try nativeIdentifier(of: target)
        #expect(identifier.value?.value?.string == record.nativeRecordID.uuidString.lowercased())
        #expect(identifier.system?.value?.url.absoluteString == FHIRExchangeIdentifiers.healthKitNativeRecord.rawValue)
    }
}
