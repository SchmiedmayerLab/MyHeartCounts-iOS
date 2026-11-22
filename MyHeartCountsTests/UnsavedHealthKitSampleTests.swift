//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveHealthKitFHIR
import HealthKit
import ModelsR4
@testable import MyHeartCounts
import Testing


/// A sample MHC couldn't save into HealthKit is uploaded with MHC stated as its source.
@Suite
struct UnsavedHealthKitSampleTests {
    /// A 120/80 blood pressure reading.
    private static func bloodPressure() -> HKCorrelation {
        func member(_ type: HKQuantityTypeIdentifier, _ value: Double) -> HKQuantitySample {
            HKQuantitySample(
                type: HKQuantityType(type),
                quantity: HKQuantity(unit: .millimeterOfMercury(), doubleValue: value),
                start: ExchangeHarness.start,
                end: ExchangeHarness.start
            )
        }
        return HKCorrelation(
            type: HKCorrelationType(.bloodPressure),
            start: ExchangeHarness.start,
            end: ExchangeHarness.start,
            objects: [member(.bloodPressureSystolic, 120), member(.bloodPressureDiastolic, 80)]
        )
    }

    /// Whether the staged record's Provenance states an author, which only a sample attributed to a source has.
    private static func statesAnAuthor(_ json: Data) throws -> Bool {
        let bundle = try JSONDecoder().decode(ModelsR4.Bundle.self, from: json)
        let provenances = bundle.entry?.compactMap { $0.resource?.get(if: Provenance.self) } ?? []
        return provenances.contains { provenance in
            provenance.entity?.contains { entity in
                entity.agent?.contains { agent in
                    agent.type?.coding?.contains { $0.code?.value?.string == "author" } == true
                } == true
            } == true
        }
    }

    @Test
    func quantitySamplesAndCorrelationsAreUnsavedSampleRecords() async throws {
        let provider = HealthKitFHIRExporter.RecordProvider.unsavedSamples
        let quantity = heartRateSample(0)
        guard case .unsavedSample(.quantitySample(let unsavedQuantity), source: _) = try await provider.record(for: quantity) else {
            Issue.record("a quantity sample isn't an unsaved quantity sample's record")
            return
        }
        #expect(unsavedQuantity === quantity)
        let correlation = Self.bloodPressure()
        guard case .unsavedSample(.correlation(let unsavedCorrelation), source: _) = try await provider.record(for: correlation) else {
            Issue.record("a correlation isn't an unsaved correlation's record")
            return
        }
        #expect(unsavedCorrelation === correlation)
        #expect(provider.voltageMeasurements(for: quantity) == 0)
    }

    @Test
    func otherSamplesAreRefused() async throws {
        let category = HKCategorySample(
            type: HKCategoryType(.chestTightnessOrPain),
            value: HKCategoryValueSeverity.mild.rawValue,
            start: ExchangeHarness.start,
            end: ExchangeHarness.start.addingTimeInterval(60)
        )
        await #expect(throws: UnsavedHealthKitSample.UnsupportedSampleError.self) {
            try await HealthKitFHIRExporter.RecordProvider.unsavedSamples.record(for: category)
        }
    }

    @Test
    func stagedUnsavedSamplesStateMHCAsTheirAuthor() async throws {
        let staging = try await HealthUploadStaging.resolvedForTesting()
        let unsaved = heartRateSample(0)
        let correlation = Self.bloodPressure()
        let plain = heartRateSample(1)
        try await staging.add([UnsavedHealthKitSample(unsaved)], ingestionTimestamp: ExchangeHarness.start)
        try await staging.add([UnsavedHealthKitSample(correlation)], ingestionTimestamp: ExchangeHarness.start)
        try await staging.add([plain], ingestionTimestamp: ExchangeHarness.start)
        let staged = try staging.drainStagedSamples()
        #expect(try Self.statesAnAuthor(#require(staged[unsaved.uuid])))
        #expect(try Self.statesAnAuthor(#require(staged[correlation.uuid])))
        // The same kind of sample, uploaded as one HealthKit holds, names no source.
        #expect(try !Self.statesAnAuthor(#require(staged[plain.uuid])))
    }
}
