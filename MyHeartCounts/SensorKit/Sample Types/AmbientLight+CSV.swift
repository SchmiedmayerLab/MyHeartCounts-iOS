//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveSensorKit
import MyHeartCountsShared
import SensorKit


extension SRAmbientLightSample.SafeRepresentation: CSVAppendableSensorSample {
    static let csvColumns = ["timestamp", "lux", "placement", "chromacityX", "chromacityY"]
    
    var csvFieldValues: [any CSVWriter.FieldValue] {
        [
            timestamp,
            lux.value,
            placement.description,
            chromacity.x,
            chromacity.y
        ]
    }
}
