//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFHIRContract
import GroveSensorKit
import GroveSensorKitFHIR
import MyHeartCountsShared
import SensorKit


extension SRAmbientLightSample.SafeRepresentation: CSVAppendableSensorSample {
    static var recordingFormat: RegisteredRecordingFormat { RegisteredRecordingFormat.ambientLightSamples }

    var recordingFields: [RecordingCSVWriter.Field] {
        [
            .timestamp(timestamp),
            .number(lux.value),
            .text(placement.description),
            .number(Double(chromacity.x)),
            .number(Double(chromacity.y))
        ]
    }
}
