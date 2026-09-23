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


/// Deletions ship as Grove Mobile Retraction Bundles minted from the same identity scope as the
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

    /// The addition path's own coordinates for one spelled-out output.
    private struct Output {
        let role: String
        let discriminator: String
        let resourceType: ResourceType
        let targetRole: RetractionTargetRole
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
        sourceType: String = "HKQuantityTypeIdentifierStepCount"
    ) throws -> HealthKitDeletedRecord {
        HealthKitDeletedRecord(
            sourceTypeIdentifier: sourceType,
            nativeRecordID: try #require(UUID(uuidString: "9512FC92-B514-4BCC-A157-050C41DAC51D")),
            detectedAt: detectedAt
        )
    }

    private static func provenance(in graph: ExchangeGraph) throws -> Provenance {
        let entry = try #require(graph.bundle.entry?.first)
        guard case .provenance(let provenance) = entry.resource else {
            Issue.record("A retraction bundle carries exactly one Provenance")
            throw CancellationError()
        }
        return provenance
    }

    private static func targets(in graph: ExchangeGraph) throws -> [DescribedTarget] {
        try provenance(in: graph).target.map { target in
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

    private static func sourceRecord(
        of record: HealthKitDeletedRecord,
        in store: FHIRExchangeStateStore,
        subject: FHIRExchangeSubject
    ) throws -> SourceRecordIdentity {
        try store.identityScope().sourceRecord(
            adapterID: "healthkit",
            sourceType: record.sourceTypeIdentifier,
            repositoryScope: try store.repositoryScope(.healthKit, subject: subject),
            nativeRecordID: record.nativeRecordID.uuidString.lowercased()
        )
    }

    /// The target the addition path's own coordinates produce for one spelled-out output.
    private static func expected(
        _ output: Output,
        of record: HealthKitDeletedRecord,
        in store: FHIRExchangeStateStore,
        subject: FHIRExchangeSubject
    ) throws -> DescribedTarget {
        let identifier = try sourceRecord(of: record, in: store, subject: subject)
            .output(role: output.role, discriminator: output.discriminator)
            .identifier
        return DescribedTarget(
            identifier: identifier.value,
            system: identifier.system.rawValue,
            resourceType: output.resourceType.rawValue,
            role: output.targetRole.rawValue
        )
    }

    private static func retraction(
        of record: HealthKitDeletedRecord,
        in store: FHIRExchangeStateStore,
        subject: FHIRExchangeSubject
    ) throws -> ExchangeGraph {
        try #require(try store.healthKitRetraction(of: record, subject: subject, recordedAt: recordedAt)).graph
    }

    @Test
    func retractionNamesTheSameIdentitiesTheAdditionMinted() throws {
        let store = FHIRExchangeStateStore()
        let subject = try Self.subject
        let record = try Self.record()
        let graph = try Self.retraction(of: record, in: store, subject: subject)
        let expectedSourceRecord = try Self.sourceRecord(of: record, in: store, subject: subject)
        let expected = try Self.expected(
            Output(role: "step-count", discriminator: "single", resourceType: .observation, targetRole: .primaryOutput),
            of: record,
            in: store,
            subject: subject
        )

        #expect(
            try Self.provenance(in: graph).entity?.first?.what.identifier?.value?.value?.string
                == expectedSourceRecord.identifier.identifier.value
        )
        #expect(try Self.targets(in: graph) == [expected])
    }

    @Test
    func retractionTargetCarriesTheLowercasedNativeRecordIdentifier() throws {
        let store = FHIRExchangeStateStore()
        let graph = try Self.retraction(of: try Self.record(), in: store, subject: try Self.subject)
        let target = try #require(try Self.provenance(in: graph).target.first)
        let native = try #require(target.extension?.first { extensionValue in
            extensionValue.url.value?.url.absoluteString == Canonicals.retractionTargetNativeIdentifier.value?.url.absoluteString
        })

        guard case .identifier(let identifier)? = native.value else {
            Issue.record("The native record identifier travels as a typed Identifier")
            return
        }
        #expect(identifier.value?.value?.string == "9512fc92-b514-4bcc-a157-050c41dac51d")
        #expect(identifier.system?.value?.url.absoluteString == FHIRExchangeIdentifiers.healthKitNativeRecord.rawValue)
    }

    /// The workout row publishes two measurements and the converter emits the session under the
    /// first, so a deleted workout must retract that exact output rather than pass as unexported.
    @Test
    func deletedWorkoutRetractsItsSessionObservation() throws {
        let store = FHIRExchangeStateStore()
        let subject = try Self.subject
        let record = try Self.record(sourceType: HKWorkoutType.workoutType().identifier)
        let expected = try Self.expected(
            Output(role: "workout", discriminator: "session", resourceType: .observation, targetRole: .primaryOutput),
            of: record,
            in: store,
            subject: subject
        )

        #expect(try Self.targets(in: Self.retraction(of: record, in: store, subject: subject)) == [expected])
    }

    /// Clinical records and CDA documents are platform-exclusive rows carrying no measurement, yet
    /// every one of them leaves as a `clinical-record` DocumentReference.
    @Test(arguments: [
        "HKClinicalTypeIdentifierLabResultRecord",
        "HKClinicalTypeIdentifierMedicationRecord",
        "HKClinicalTypeIdentifierVitalSignRecord",
        "HKDocumentTypeIdentifierCDA"
    ])
    func deletedClinicalDocumentRetractsItsSourceArtifact(sourceType: String) throws {
        let store = FHIRExchangeStateStore()
        let subject = try Self.subject
        let record = try Self.record(sourceType: sourceType)
        let expected = try Self.expected(
            Output(role: "clinical-record", discriminator: "single", resourceType: .documentReference, targetRole: .sourceArtifact),
            of: record,
            in: store,
            subject: subject
        )

        #expect(try Self.targets(in: Self.retraction(of: record, in: store, subject: subject)) == [expected])
    }

    /// An ECG that carried a period average published it as its own output, which the waveform's
    /// retraction alone would orphan.
    @Test
    func deletedElectrocardiogramAlsoRetractsItsAverageHeartRate() throws {
        let store = FHIRExchangeStateStore()
        let subject = try Self.subject
        let record = try Self.record(sourceType: HKObjectType.electrocardiogramType().identifier)
        let expected = try [
            Output(role: "electrocardiogram", discriminator: "single", resourceType: .observation, targetRole: .primaryOutput),
            Output(role: "average-heart-rate", discriminator: "single", resourceType: .observation, targetRole: .childOutput)
        ].map { try Self.expected($0, of: record, in: store, subject: subject) }

        #expect(try Self.targets(in: Self.retraction(of: record, in: store, subject: subject)) == expected)
    }

    /// A record class Grove never exports has nothing to retract, so no event is spent on it.
    @Test(arguments: [
        "HKVisionPrescriptionTypeIdentifier",
        "HKDataTypeIdentifierAudiogram",
        "HKCorrelationTypeIdentifierFood",
        "HKQuantityTypeIdentifierBloodPressureSystolic",
        "HKCharacteristicTypeIdentifierBloodType"
    ])
    func unexportedSourceTypesMintNoRetraction(sourceType: String) throws {
        let store = FHIRExchangeStateStore()
        let retraction = try store.healthKitRetraction(
            of: try Self.record(sourceType: sourceType),
            subject: try Self.subject,
            recordedAt: Self.recordedAt
        )

        #expect(retraction == nil)
        #expect(try !store.hasPersistedStateForTesting)
    }

    /// The end-to-end agreement the two halves of one record's lifecycle owe each other.
    @Test
    func retractionNamesTheOutputTheConverterActuallyMinted() throws {
        let store = FHIRExchangeStateStore()
        let subject = try Self.subject
        let sample = HKQuantitySample(
            type: HKQuantityType(.stepCount),
            quantity: HKQuantity(unit: .count(), doubleValue: 42),
            start: Self.detectedAt - 3600,
            end: Self.detectedAt - 3540
        )
        let conversion = try HealthKitConverter().convert(
            sample,
            context: try store.healthKitConversion(
                for: sample,
                subject: subject,
                conversionInstant: Self.detectedAt - 3000
            ).context
        )
        let graph = try Self.retraction(
            of: HealthKitDeletedRecord(
                sourceTypeIdentifier: sample.sampleType.identifier,
                nativeRecordID: sample.uuid,
                detectedAt: Self.detectedAt
            ),
            in: store,
            subject: subject
        )

        #expect(try Self.targets(in: graph).map(\.identifier) == [conversion.primary.identifiers.primaryOutput.identifier.value])
    }

    /// HealthKit states no deletion time, so the retraction occurred when the anchored query reported
    /// it and was recorded when the drain assembled it.
    @Test
    func retractionOccursAtDetectionAndIsRecordedAtAssembly() throws {
        let store = FHIRExchangeStateStore()
        let record = try Self.record()
        let graph = try Self.retraction(of: record, in: store, subject: try Self.subject)
        let provenance = try Self.provenance(in: graph)
        guard case .dateTime(let occurred)? = provenance.occurred else {
            Issue.record("A detected deletion occurs at one instant")
            return
        }

        #expect(try occurred.value?.asNSDate() == Self.detectedAt)
        #expect(try provenance.recorded.value?.asNSDate() == Self.recordedAt)
    }
}
