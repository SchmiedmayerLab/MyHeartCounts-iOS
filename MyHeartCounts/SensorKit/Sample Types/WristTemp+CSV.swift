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
import SensorKit


extension SRWristTemperatureSession: CSVConvertibleSensorSample {
    func csvData() throws -> Data {
        guard let columns = RegisteredRecordingFormat.wristTemperatureSamples.csvColumns else {
            throw SensorKitUploadError.formatIsNotTabular(.wristTemperatureSamples)
        }
        var writer = RecordingCSVWriter(columns: columns)
        for temp in self.temperatures {
            try writer.append([
                .timestamp(temp.timestamp),
                .number(temp.value.converted(to: .celsius).value),
                .number(temp.errorEstimate.converted(to: .celsius).value),
                .text(try temp.condition.csvStringValue())
            ])
        }
        return writer.data()
    }
    
    func retryEvidence(csvData: Data) -> Data {
        let versionData = Data(version.utf8)
        var byteCount = UInt64(versionData.count).bigEndian
        var evidence = Data()
        withUnsafeBytes(of: &byteCount) { evidence.append(contentsOf: $0) }
        evidence.append(versionData)
        evidence.append(csvData)
        return evidence
    }

    func groveRecord(
        sourceRecordID: SensorKitSourceRecordID,
        nativeRecording: SensorKitNativeRecording
    ) throws -> SensorKitRecord {
        let temperatures = Array(temperatures)
        guard let coverageStart = temperatures.lazy.map(\.timestamp).min(),
              let coverageEnd = temperatures.lazy.map(\.timestamp).max() else {
            throw SensorKitUploadError.emptyWristTemperatureSession
        }
        return .wristTemperature(SensorKitWristTemperatureRecord(
            sourceRecordID: sourceRecordID,
            coverage: DateInterval(start: coverageStart, end: coverageEnd),
            sampleCount: temperatures.count,
            algorithmVersion: version,
            nativeRecording: nativeRecording
        ))
    }
}


extension SRWristTemperature.Condition {
    func csvStringValue() throws -> String {
        let knownRawValue = Self.offWrist.rawValue | Self.onCharger.rawValue | Self.inMotion.rawValue
        let unknownRawValue = rawValue & ~knownRawValue
        guard unknownRawValue == 0 else {
            throw SensorKitUploadError.unknownWristTemperatureConditionBits(unknownRawValue)
        }

        var values: [String] = []
        if self.contains(.offWrist) {
            values.append("offWrist")
        }
        if self.contains(.onCharger) {
            values.append("onCharger")
        }
        if self.contains(.inMotion) {
            values.append("inMotion")
        }
        return values.joined(separator: ",")
    }
}
