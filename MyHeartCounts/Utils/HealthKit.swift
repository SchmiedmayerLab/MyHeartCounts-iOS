//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFoundation
import GroveHealthKit
import GroveHealthKitFHIR
import HealthKit
import ModelsR4
import MyHeartCountsShared


extension HealthKit {
    /// Deletes all samples this app saved to HealthKit, across all well-known sample types.
    ///
    /// HealthKit only lets an app delete the samples it saved itself; sample types the app can't query are skipped.
    func deleteAllSamplesSavedByThisApp() async throws {
        func imp<Sample>(_ sampleType: some AnySampleType<Sample>) async throws {
            let sampleType = SampleType(sampleType)
            guard let samples = try? await query(
                sampleType,
                timeRange: .ever,
                predicate: HKQuery.predicateForObjects(from: .default())
            ) else {
                return
            }
            if !samples.isEmpty {
                try await healthStore.delete(samples)
            }
        }
        for sampleType in HKObjectType.allKnownObjectTypes.compactMap(\.sampleType) {
            try await imp(sampleType)
        }
    }
}


extension HKUnit {
    /// Attempts to create a `HKUnit` from a unit string.
    static func parse(_ unitString: String, resolveFHIRUnits: Bool) -> HKUnit? {
        if let unit = Self.parse(unitString) {
            unit
        } else {
            resolveFHIRUnits ? .parseFromFHIRUnit(unitString) : nil
        }
    }
}


// MARK: FHIR
extension HKUnit {
    /// Display spellings producers use that no Grove contract states.
    ///
    /// `Quantity.unit` is a human label rather than a coded value — only `Quantity.code` is UCUM —
    /// so a producer is free to write `C` for Celsius. Grove publishes only the displays its own
    /// contracts state, which is `Cel`, so a spelling seen in the wild is matched here.
    private static let producerUnitAliases: [String: HKUnit] = ["C": .degreeCelsius()]

    /// The HealthKit unit a FHIR unit names, whether the string is the UCUM code or the display.
    ///
    /// Grove publishes the correspondence because it cannot be derived: HealthKit does not parse
    /// UCUM, and `HKUnit(from: "Cel")` raises rather than returning degrees Celsius.
    static func parseFromFHIRUnit(_ unitString: String) -> HKUnit? {
        HealthKitCatalog.unit(forUnitSpelling: unitString) ?? producerUnitAliases[unitString]
    }
}
