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
import HealthKit
@testable import MyHeartCounts
import Testing


/// Grove's conversion refusals are deliberate and permanent, so a refused record must cost only
/// itself. Failing its batch instead retains the query anchor, which redelivers the same record
/// forever and blocks every newer sample of its type.
@Suite
struct HealthKitRefusalIsolationTests {
    private static let healthKit = HealthKit()

    private static let start = Date(timeIntervalSince1970: 1_788_000_000)

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
        let exporter = try ExchangeHarness().exporter()
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

    /// A refused sample stages no row, on its delivery and on every redelivery, and neither delivery fails, so its anchor
    /// commits and newer samples of its type follow.
    @Test
    func refusedSampleStagesNothingOnEveryDelivery() async throws {
        let sample = Self.refusedSample
        let staging = try await HealthUploadStaging.resolvedForTesting()

        try await staging.add([sample])
        #expect(try staging.fetchCount(of: HealthUploadStaging.PendingSampleRecord.self) == 0)

        try await staging.add([sample])
        #expect(try staging.fetchCount(of: HealthUploadStaging.PendingSampleRecord.self) == 0)
    }

    @Test
    func oneRefusedSampleStillStagesTheRest() async throws {
        let healthUploadStaging = try await HealthUploadStaging.resolvedForTesting()
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
