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
            ofType sampleType: SampleType<Sample>
        ) async throws -> HealthKitAnchorCommitAction? { nil }
    }

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
        let stateStore = FHIRExchangeStateStore()
        let payload = try await sample.prepareFHIRPayload(
            conversionInstant: Self.start,
            subject: try Self.subject,
            stateStore: stateStore,
            using: HealthKit()
        )

        #expect(payload.entries.isEmpty)
        #expect(payload.refusals.map(\.sourceID) == [sample.uuid])
        #expect(payload.refusals.first?.reason == .componentSampleRequiresCorrelation(
            sampleType: HKQuantityTypeIdentifier.bloodPressureSystolic.rawValue
        ))
    }

    /// A refusal has no graph to reproduce, so it releases its reservation rather than leaving the
    /// ledger to grow: a later event takes the next sequence instead of finding the abandoned one.
    @Test
    func refusalReleasesItsReservation() async throws {
        let sample = Self.refusedSample
        let subject = try Self.subject
        let stateStore = FHIRExchangeStateStore()
        _ = try await sample.prepareFHIRPayload(
            conversionInstant: Self.start,
            subject: subject,
            stateStore: stateStore,
            using: HealthKit()
        )

        let laterEvent = try stateStore.event(
            key: stateStore.healthKitEventKey(
                subject: subject,
                sourceType: sample.sampleType.identifier,
                nativeRecordID: sample.uuid
            ),
            recordedAt: Self.start,
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
                researchStudyIDs: []
            )
        )
        #expect(laterEvent.sequence == 2)
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
