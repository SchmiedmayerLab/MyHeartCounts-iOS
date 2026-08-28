//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import CoreMotion
import Foundation
import GroveFHIRContract
import GroveSensorKit
import GroveSensorKitFHIR
import MyHeartCountsShared


extension CMPedometerData.SafeRepresentation: CSVAppendableSensorSample {
    static var recordingFormat: RegisteredRecordingFormat { RegisteredRecordingFormat.pedometerSamples }

    var recordingFields: [RecordingCSVWriter.Field] {
        [
            .timestamp(timeRange.lowerBound),
            .timestamp(timeRange.upperBound),
            .integer(numberOfSteps),
            distance.map { .number($0) } ?? .absent,
            floorsAscended.map { .integer($0) } ?? .absent,
            floorsDescended.map { .integer($0) } ?? .absent,
            currentPace.map { .number($0) } ?? .absent,
            currentCadence.map { .number($0) } ?? .absent,
            averageActivePace.map { .number($0) } ?? .absent
        ]
    }
}
