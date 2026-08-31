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

    private static let deletedAt = Date(timeIntervalSince1970: 1_788_000_000)

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
            deletedAt: deletedAt
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

    /// The target the addition path's own coordinates produce for one spelled-out output.
    private static func expected(
        _ output: HealthKitRetraction.Output,
        of record: HealthKitDeletedRecord,
        in store: FHIRExchangeStateStore,
        subject: FHIRExchangeSubject
    ) throws -> DescribedTarget {
        let identifier = try store.identityScope().sourceOutput(
            adapterID: "healthkit",
            sourceType: record.sourceTypeIdentifier,
            repositoryScope: try store.repositoryScope(.healthKit, subject: subject),
            nativeRecordID: record.nativeRecordID.uuidString.lowercased(),
            outputRole: output.role,
            outputDiscriminator: output.discriminator
        )
        return DescribedTarget(
            identifier: identifier.value,
            system: identifier.systemValue,
            resourceType: output.resourceType.rawValue,
            role: output.targetRole.rawValue
        )
    }

    private static func retraction(
        of record: HealthKitDeletedRecord,
        in store: FHIRExchangeStateStore,
        subject: FHIRExchangeSubject
    ) throws -> ExchangeGraph {
        try #require(try store.healthKitRetraction(of: record, subject: subject, recordedAt: deletedAt)).graph
    }

    @Test
    func retractionNamesTheSameIdentitiesTheAdditionMinted() throws {
        let store = FHIRExchangeStateStore()
        let subject = try Self.subject
        let record = try Self.record()
        let graph = try Self.retraction(of: record, in: store, subject: subject)
        let expectedSourceRecord = try store.identityScope().sourceRecord(
            adapterID: "healthkit",
            sourceType: record.sourceTypeIdentifier,
            repositoryScope: try store.repositoryScope(.healthKit, subject: subject),
            nativeRecordID: record.nativeRecordID.uuidString.lowercased()
        )
        let expected = try Self.expected(
            .init(role: "step-count", discriminator: "single", resourceType: .observation, targetRole: .primaryOutput),
            of: record,
            in: store,
            subject: subject
        )

        #expect(
            try Self.provenance(in: graph).entity?.first?.what.identifier?.value?.value?.string
                == expectedSourceRecord.value
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
            .init(role: "workout", discriminator: "session", resourceType: .observation, targetRole: .primaryOutput),
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
            .init(
                role: "clinical-record",
                discriminator: "single",
                resourceType: .documentReference,
                targetRole: .sourceArtifact
            ),
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
            Self.expected(
                .init(
                    role: "electrocardiogram",
                    discriminator: "single",
                    resourceType: .observation,
                    targetRole: .primaryOutput
                ),
                of: record,
                in: store,
                subject: subject
            ),
            Self.expected(
                .init(
                    role: "average-heart-rate",
                    discriminator: "single",
                    resourceType: .observation,
                    targetRole: .childOutput
                ),
                of: record,
                in: store,
                subject: subject
            )
        ]

        #expect(try Self.targets(in: Self.retraction(of: record, in: store, subject: subject)) == expected)
    }

    /// A record class the app never exported has nothing to retract, so no event is spent on it.
    ///
    /// Routes and heartbeat series are recording documents the app has no fetch path for, while the
    /// audiogram and food rows are published as supported though no converter binding emits them.
    @Test(arguments: [
        "HKWorkoutRouteTypeIdentifier",
        "HKDataTypeIdentifierHeartbeatSeries",
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
            recordedAt: Self.deletedAt
        )

        #expect(retraction == nil)
        #expect(try !store.hasPersistedStateForTesting)
    }

    /// The retraction re-derives its target from the table the converter mints from, so a row that
    /// resolves to an Observation must resolve to one its own published measurements name.
    @Test
    func everyRetractedObservationRoleIsPublishedByItsOwnRow() throws {
        let workout = HKWorkoutType.workoutType().identifier
        for entry in HealthKitCatalog.entries {
            guard let primary = HealthKitRetraction.outputs(forSourceType: entry.sourceTypeIdentifier).first,
                  primary.resourceType == .observation else {
                continue
            }
            #expect(
                entry.measurements.map(\.id).contains(primary.role),
                "\(entry.sourceTypeIdentifier) retracts '\(primary.role)', which its own row does not publish"
            )
            #expect(primary.targetRole == .primaryOutput)
            #expect(
                primary.discriminator == (entry.sourceTypeIdentifier == workout ? "session" : "single"),
                "\(entry.sourceTypeIdentifier) retracts an unexpected output discriminator"
            )
        }
    }

    /// The end-to-end agreement the two halves of one record's lifecycle owe each other.
    @Test
    func retractionNamesTheOutputTheConverterActuallyMinted() throws {
        let store = FHIRExchangeStateStore()
        let subject = try Self.subject
        let sample = HKQuantitySample(
            type: HKQuantityType(.stepCount),
            quantity: HKQuantity(unit: .count(), doubleValue: 42),
            start: Self.deletedAt,
            end: Self.deletedAt + 60
        )
        let conversion = try HealthKitConverter().convert(
            sample,
            context: try store.healthKitConversion(
                for: sample,
                subject: subject,
                conversionInstant: Self.deletedAt
            ).context
        )
        let graph = try Self.retraction(
            of: HealthKitDeletedRecord(
                sourceTypeIdentifier: sample.sampleType.identifier,
                nativeRecordID: sample.uuid,
                deletedAt: Self.deletedAt
            ),
            in: store,
            subject: subject
        )

        #expect(try Self.targets(in: graph).map(\.identifier) == [conversion.graphIdentifiers.primaryOutput.value])
    }
}
