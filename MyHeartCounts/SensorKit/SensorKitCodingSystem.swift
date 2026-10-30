//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import GroveSensorKit
import ModelsR4


struct SensorKitCodingSystem: CodingProtocol {
    static let system: FHIRPrimitive<FHIRURI> = "https://developer.apple.com/documentation/sensorkit"
    
    let code: FHIRPrimitive<FHIRString>
    let display: FHIRPrimitive<FHIRString>?
    
    init(_ code: String, display: String? = nil) {
        self.code = code.asFHIRStringPrimitive()
        self.display = display?.asFHIRStringPrimitive()
    }
    
    init(_ sensor: Sensor<some Any>) {
        self.init(
            sensor.id,
            display: sensor.displayName
        )
    }
    
    // periphery:ignore - API
    func property(_ name: String, display: String? = nil) -> Self {
        Self("\(code.value?.string ?? "")/\(name)", display: display)
    }
}
