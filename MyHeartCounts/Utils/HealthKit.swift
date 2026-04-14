//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import HealthKit
import SpeziHealthKitFHIR
import SpeziFoundation


extension HKUnit {
    /// Attempts to create a `HKUnit` from a unit string.
    static func parse(_ unitString: String) -> HKUnit? {
        // ideally this would be a failing convenience init, but the language isn't able to express that.
        // (we could define it as a category in ObjC, but this is good enough...)
        (try? catchingNSException {
            HKUnit(from: unitString)
        }) ?? .parseFromFHIRUnit(unitString)
    }
}


// MARK: FHIR
extension HKUnit {
    private static let defaultFHIRUnitsMapping: [String: Set<HKUnit>] = {
        HKSampleMapping.default.quantitySampleMapping.reduce(into: [:]) { acc, entry in
            let mappedUnit = entry.value.unit
            if let code = mappedUnit.code {
                acc[code, default: []].insert(mappedUnit.hkunit)
            }
            acc[mappedUnit.unit, default: []].insert(mappedUnit.hkunit)
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
