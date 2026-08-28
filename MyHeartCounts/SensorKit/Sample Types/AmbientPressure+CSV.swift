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


extension CMRecordedPressureData.SafeRepresentation: CSVAppendableSensorSample {
    static var recordingFormat: RegisteredRecordingFormat { RegisteredRecordingFormat.ambientPressureSamples }

    var recordingFields: [RecordingCSVWriter.Field] {
        [
            .timestamp(timestamp),
            // Rendered as text: a UInt64 identifier does not fit Int on every platform.
            .text(String(identifier)),
            .number(pressure.value),
            .number(temperature.value)
        ]
    }
}
