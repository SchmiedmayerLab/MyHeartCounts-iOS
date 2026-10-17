//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import Grove
import GroveFHIRContract
import GroveHealthKit
import GroveHealthKitFHIR
import GroveTesting
import HealthKit
@testable import MyHeartCounts
import Testing


/// Grove's conversion refusals are deliberate and permanent, so a refused record must cost only
/// itself. Failing its batch instead retains the query anchor, which redelivers the same record
/// forever and blocks every newer sample of its type.
@Suite
struct HealthKitRefusalIsolationTests {
    private actor FakeStandard: Standard, HealthKitConstraint {
        func handleNewSamples<Sample>(
            _ addedSamples: some Collection<Sample> & Sendable,
            ofType sampleType: SampleType<Sample>
        ) async throws -> HealthKitAnchorCommitAction? { nil }

        func handleDeletedObjects<Sample>(
            _ deletedObjects: some Collection<HKDeletedObject> & Sendable,
            ofType sampleType: SampleType<Sample>,
            deletedAfter: Date?
        ) async throws -> HealthKitAnchorCommitAction? { nil }
    }
    
    private static let healthKit = HealthKit()

    private static let start = Date(timeIntervalSince1970: 1_788_000_000)

    private static var subject: FHIRExchangeSubject {
        get throws {
            try FHIRExchangeSubject(identity: BusinessIdentifier(
                system: FHIRExchangeIdentifiers.participant,
                value: "test"
            ))
        }
    }

    /// A bare systolic sample converts only inside the correlation that admits it.
    private static var refusedSample: HKQuantitySample {
        HKQuantitySample(
            type: HKQuantityType(.bloodPressureSystolic),
            quantity: HKQuantity(unit: .millimeterOfMercury(), doubleValue: 118),
            start: start,
            end: start
        )
    }

    @Test
    func refusalIsRecordedInsteadOfFailingTheRecord() async throws {
        let sample = Self.refusedSample
        let exporter = try FHIRExchangeStateStore().healthKitExporter(subject: try Self.subject, ledger: .forTesting())
        var entries: [PreparedHealthObservationFHIRPayload.Entry] = []
        let export = try await exporter.exportBatch([sample], at: Self.start, recordProvider: .healthKit(Self.healthKit)) { entry in
            entries.append(entry)
        }

        #expect(entries.isEmpty)
        #expect(export.refusals.map(\.sourceID) == [sample.uuid])
        #expect(export.refusals.first?.reason == .componentRequiresCorrelation(.bloodPressureSystolic))
        #expect(
            export.refusals.first?.reason.diagnostic.code
                == ExchangeGraphRule.healthkitInputComponentRequiresCorrelation.rawValue
        )
    }

    /// M6: a refusal holds its reservation like a graph does, until the delivery's anchor commits. Re-exporting the
    /// refused sample before then reuses its sequence; after, it takes the next one.
    @Test
    func refusalHoldsItsReservationUntilTheAnchorCommits() async throws {
        let sample = Self.refusedSample
        let staging = HealthUploadStaging.forTesting(persistence: .inMemory, subject: try Self.subject)
        await withDependencyResolution(standard: FakeStandard()) {
            staging
            HealthKit()
        }
        let ledger = try #require(staging.testing).ledger

        let delivery = try await staging.add([sample])
        let reserved = try ledger.producerEntry()
        #expect(try ledger.entryKeys(prefixedBy: "event/").count == 1)

        let redelivery = try await staging.add([sample])
        #expect(try ledger.producerEntry().next == reserved.next, "the redelivery reused the refused sample's reservation")
        #expect(try ledger.entryKeys(prefixedBy: "event/").count == 1)

        delivery.completeAfterSourceAcknowledgement()
        #expect(try ledger.entryKeys(prefixedBy: "event/").count == 1, "the redelivery still holds the event")
        redelivery.completeAfterSourceAcknowledgement()
        #expect(try ledger.entryKeys(prefixedBy: "event/").isEmpty)

        _ = try await staging.add([sample])
        let next = try #require(UInt64(reserved.next)).advanced(by: 1)
        #expect(try ledger.producerEntry().next == String(next), "the next export of the sample is a new event")
        #expect(try staging.fetchCount(of: HealthUploadStaging.PendingSampleRecord.self) == 0)
    }

    @Test
    func oneRefusedSampleStillStagesTheRest() async throws {
        let healthUploadStaging = HealthUploadStaging.forTesting(
            persistence: .inMemory,
            subject: try Self.subject
        )
        await withDependencyResolution(standard: FakeStandard()) {
            healthUploadStaging
            HealthKit()
        }
        let steps = HKQuantitySample(
            type: .init(.stepCount),
            quantity: HKQuantity(unit: .count(), doubleValue: 52),
            start: Self.start,
            end: Self.start + 60
        )

        try await healthUploadStaging.add([Self.refusedSample, steps])

        #expect(try healthUploadStaging.fetchCount(of: HealthUploadStaging.PendingSampleRecord.self) == 1)
    }
}
