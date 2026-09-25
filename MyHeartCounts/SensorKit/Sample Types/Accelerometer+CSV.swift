//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import CoreMotion
import GroveSensorKit
import MyHeartCountsShared


extension CMRecordedAccelerometerData.SafeRepresentation: CSVAppendableSensorSample {
    static let csvColumns = ["timestamp", "identifier", "x", "y", "z"]
    
    var csvFieldValues: [any CSVWriter.FieldValue] {
        [
            timestamp,
            identifier,
            acceleration.x,
            acceleration.y,
            acceleration.z
        ]
    }
}
