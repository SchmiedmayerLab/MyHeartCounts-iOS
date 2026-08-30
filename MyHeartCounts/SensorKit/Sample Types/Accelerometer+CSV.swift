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

    var recordingBatchIdentifier: UInt64? {
        identifier
    }

    static func structuredGroveRecord(
        sourceRecordID: SensorKitSourceRecordID,
        coverage: DateInterval,
        sampleCount: Int,
        batchCount: Int,
        nativeRecording: SensorKitNativeRecording
    ) -> SensorKitRecord? {
        .accelerometer(SensorKitAccelerometerRecord(
            sourceRecordID: sourceRecordID,
            coverage: coverage,
            sampleCount: sampleCount,
            batchCount: batchCount,
            nativeRecording: nativeRecording
        ))
    }
}
