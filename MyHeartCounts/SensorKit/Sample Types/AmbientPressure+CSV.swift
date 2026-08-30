//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import CoreMotion
import Foundation
import GroveSensorKit
import MyHeartCountsShared


extension CMRecordedPressureData.SafeRepresentation: CSVAppendableSensorSample {
    static let csvColumns = ["timestamp", "identifier", "pressure", "temperature"]
    
    var csvFieldValues: [any CSVWriter.FieldValue] {
        [
            timestamp,
            identifier,
            pressure.value,
            temperature.value
        ]
    }
}
