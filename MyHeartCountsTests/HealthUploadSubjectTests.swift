//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import GroveHealthKit
import HealthKit
@testable import MyHeartCounts
import Testing


/// The subject converted samples are attributed to.
///
/// Attribution is the one thing conversion cannot guess at, so the production path reads it from
/// the signed-in account and refuses without one. Tests reach it through a `#if DEBUG` seam that a
/// release build does not contain, which is what keeps that refusal honest.
@Suite
struct HealthUploadSubjectTests {
    @Test
    func conversionRefusesWhenNoAccountIsPresent() async throws {
        let sample = HKQuantitySample(
            type: SampleType.stepCount.hkSampleType,
            quantity: HKQuantity(unit: .count(), doubleValue: 12),
            start: Date(),
            end: Date()
        )
        let uploader = HealthKitSamplesFHIRUploader(standard: nil)
        do {
            _ = try await uploader.process([sample], of: .stepCount)
            Issue.record("conversion attributed samples with no account present")
        } catch HealthKitSamplesFHIRUploader.ProcessingError.missingStandard {
            // Expected: with no account there is nobody to attribute the Observations to.
        }
    }
}
