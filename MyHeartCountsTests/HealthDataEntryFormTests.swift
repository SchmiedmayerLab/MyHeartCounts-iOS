//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveHealthKit
import HealthKit
@testable import MyHeartCounts
import Testing


@Suite
struct HealthDataEntryFormTests {
    private static func bloodGlucoseSample() -> HKQuantitySample {
        HKQuantitySample(
            type: HKQuantityType(.bloodGlucose),
            quantity: HKQuantity(unit: .milligramsPerDeciliter, doubleValue: 95),
            start: .now,
            end: .now,
            metadata: [HKMetadataKeyWasUserEntered: true]
        )
    }

    @Test
    func healthWriteAccess() {
        // a form without HealthKit types (e.g., for a custom sample) needs no access, and shows no notice
        #expect(HealthWriteAccess([]) == .allowed)
        #expect(HealthWriteAccess([.sharingAuthorized]) == .allowed)
        #expect(HealthWriteAccess([.sharingAuthorized, .sharingAuthorized]) == .allowed)
        // one type MHC hasn't asked for yet is enough for the notice (and the Allow button)
        #expect(HealthWriteAccess([.notDetermined]) == .notAskedYet)
        #expect(HealthWriteAccess([.sharingAuthorized, .notDetermined]) == .notAskedYet)
        // a denied type wins over one MHC hasn't asked for yet: asking again wouldn't help
        #expect(HealthWriteAccess([.sharingDenied]) == .denied)
        #expect(HealthWriteAccess([.notDetermined, .sharingDenied]) == .denied)
        #expect(HealthWriteAccess([.sharingAuthorized, .sharingDenied]) == .denied)
    }

    @Test
    func healthKitEntryIsSavedIntoTheHealthAppOnlyWithAccess() {
        let sample = Self.bloodGlucoseSample()
        let entry = HealthDataEntry.healthKit([sample])
        guard case .healthApp(let saved) = entry.destination(given: .allowed) else {
            Issue.record("with access, the entry isn't saved into the Health app")
            return
        }
        #expect(saved == [sample])
        // without access, the very samples go straight into the upload queue instead
        for access in [HealthWriteAccess.notAskedYet, .denied] {
            guard case .healthKitSamplesUpload(let uploaded) = entry.destination(given: access) else {
                Issue.record("with access \(access), the entry isn't uploaded")
                continue
            }
            #expect(uploaded == [sample])
        }
    }

    @Test
    func customEntryIsAlwaysUploaded() {
        let sample = QuantitySample(
            id: UUID(),
            sampleType: .custom(.hbA1c),
            unit: .percent(),
            value: 5.4,
            date: .now
        )
        for access in [HealthWriteAccess.allowed, .notAskedYet, .denied] {
            guard case .customSampleUpload(let uploaded) = HealthDataEntry.custom(sample).destination(given: access) else {
                Issue.record("with access \(access), the custom sample isn't uploaded")
                continue
            }
            #expect(uploaded.id == sample.id)
        }
    }
}
