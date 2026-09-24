//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFoundation
import GroveHealthKitFHIR
import HealthKit
import ModelsR4
import MyHeartCountsShared


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
    private static let defaultFHIRUnitsMapping: [String: Set<HKUnit>] = {
        SampleTypesFHIRMapping.default.quantityTypesMapping.reduce(into: [:]) { acc, entry in
            let mappedUnit = entry.value.unit
            if let code = mappedUnit.code?.value?.string {
                acc[code, default: []].insert(mappedUnit.hkUnit)
            }
            acc[mappedUnit.unit, default: []].insert(mappedUnit.hkUnit)
        }
    }()
    
    static func parseFromFHIRUnit(_ unitString: String) -> HKUnit? {
        guard let units = defaultFHIRUnitsMapping[unitString], !units.isEmpty else {
            return nil
        }
        if units.count > 1 {
            print("Error: found multiple units for unitString '\(unitString)'. returning nil.")
            return nil
        } else {
            return units.first
        }
    }
}
