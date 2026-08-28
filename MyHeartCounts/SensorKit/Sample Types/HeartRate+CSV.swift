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


extension CMHighFrequencyHeartRateData.SafeRepresentation: CSVAppendableSensorSample {
    static var recordingFormat: RegisteredRecordingFormat { RegisteredRecordingFormat.heartRateSamples }

    var recordingFields: [RecordingCSVWriter.Field] {
        [.timestamp(timestamp), .number(value), .integer(confidence.rawValue)]
    }
}
