//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import CoreMotion
import GroveFHIRContract
import GroveSensorKit
import GroveSensorKitFHIR
import MyHeartCountsShared


extension CMRecordedAccelerometerData.SafeRepresentation: CSVAppendableSensorSample {
    static var recordingFormat: RegisteredRecordingFormat { RegisteredRecordingFormat.triaxialAccelerationSamples }

    var recordingFields: [RecordingCSVWriter.Field] {
        [
            .timestamp(timestamp),
            // Rendered as text: a UInt64 identifier does not fit Int on every platform.
            .text(String(identifier)),
            .number(acceleration.x),
            .number(acceleration.y),
            .number(acceleration.z)
        ]
    }
}
