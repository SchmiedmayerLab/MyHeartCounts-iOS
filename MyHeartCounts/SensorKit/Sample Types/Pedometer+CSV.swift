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


extension CMPedometerData.SafeRepresentation: CSVAppendableSensorSample {
    static let csvColumns = [
        "start", "end", "steps", "distance", "floorsUp", "floorsDown", "currentPace", "currentCadence", "avgActivePace"
    ]
    
    var csvFieldValues: [any CSVWriter.FieldValue] {
        [
            timeRange.lowerBound,
            timeRange.upperBound,
            numberOfSteps,
            distance,
            floorsAscended,
            floorsDescended,
            currentPace,
            currentCadence,
            averageActivePace
        ]
    }
}
