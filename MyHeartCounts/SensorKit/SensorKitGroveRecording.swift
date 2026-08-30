//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveSensorKit
import GroveSensorKitFHIR
import SensorKit


/// The Grove catalog row backing a SensorKit stream, and the format its payload is written in.
struct SensorKitGroveStream {
    private static let sourceTokens: [SRSensor: String] = [
        .heartRate: "SRSensor.heartRate",
        .accelerometer: "SRSensor.accelerometer",
        .ambientLightSensor: "SRSensor.ambientLightSensor",
        .ambientPressure: "SRSensor.ambientPressure",
        .pedometerData: "SRSensor.pedometerData",
        .wristTemperature: "SRSensor.wristTemperature",
        .visits: "SRSensor.visits",
        .onWristState: "SRSensor.onWristState",
        .deviceUsageReport: "SRSensor.deviceUsageReport",
        .electrocardiogram: "SRSensor.electrocardiogram",
        .photoplethysmogram: "SRSensor.photoplethysmogram"
    ]

    private static let formats: [SRSensor: RegisteredRecordingFormat] = [
        .heartRate: .heartRateSamples,
        .accelerometer: .triaxialAccelerationSamples,
        .ambientLightSensor: .ambientLightSamples,
        .ambientPressure: .ambientPressureSamples,
        .pedometerData: .pedometerSamples,
        .wristTemperature: .wristTemperatureSamples,
        .electrocardiogram: .nativeRecording,
        .photoplethysmogram: .photoplethysmogramSamples
    ]

    /// The stream's source token in the Grove SensorKit catalog.
    let sourceToken: String
    /// The registry format the stream writes, absent when a structured source has no sidecar.
    private let format: RegisteredRecordingFormat?

    var recordingFormat: RegisteredRecordingFormat {
        get throws {
            guard let format else {
                throw SensorKitGroveRecordingError.sourceHasNoRecordingFormat(sourceToken)
            }
            return format
        }
    }

    var fileExtension: String {
        get throws {
            let recordingFormat = try recordingFormat
            if recordingFormat.csvColumns != nil {
                return "csv"
            }
            return recordingFormat == .photoplethysmogramSamples ? "mhcPPG" : "json"
        }
    }

    init(_ sensor: some AnySensor) throws {
        guard let sourceToken = Self.sourceTokens[sensor.srSensor] else {
            throw SensorKitGroveRecordingError.unsupportedSensor(sensor.id)
        }
        let format = Self.formats[sensor.srSensor]
        guard let entry = SensorKitCatalog.current.entries.first(where: { $0.sourceToken == sourceToken }) else {
            throw SensorKitGroveRecordingError.unsupportedSensor(sensor.id)
        }
        if let format, !entry.rawFormats.contains(format) {
            throw SensorKitGroveRecordingError.unadmittedFormat(sourceToken: sourceToken, format: format)
        }
        self.sourceToken = sourceToken
        self.format = format
    }
}


enum SensorKitGroveRecordingError: Error {
    case unsupportedSensor(String)
    case sourceHasNoRecordingFormat(String)
    case unadmittedFormat(sourceToken: String, format: RegisteredRecordingFormat)
}


/// Builds complete Grove SensorKit exchange graphs from already-fetched evidence.
enum SensorKitGroveRecording {
    static func raw( // swiftlint:disable:this function_parameter_count
        payload: Data,
        reservation: SensorKitRecordReservation,
        stream: SensorKitGroveStream,
        sidecarPath: String,
        title: String,
        effectiveTimeRange: Swift.Range<Date>
    ) throws -> SensorKitConversion {
        let record = try SensorKitRawRecord(
            sourceRecordID: reservation.sourceRecordID,
            sourceToken: stream.sourceToken,
            effectivePeriod: DateInterval(
                start: effectiveTimeRange.lowerBound,
                end: effectiveTimeRange.upperBound
            ),
            nativeRecording: try SensorKitNativeRecording(
                title: title,
                format: stream.recordingFormat,
                payload: .sidecar(path: sidecarPath, bytes: payload),
                admission: .callerAuthorizedOpaquePayload
            )
        )
        return try SensorKitConverter().convert(.raw(record), context: reservation.context)
    }

    /// Converts one already-built Grove record into its graph.
    static func convert(
        _ record: SensorKitRecord,
        reservation: SensorKitRecordReservation
    ) throws -> SensorKitConversion {
        try SensorKitConverter().convert(record, context: reservation.context)
    }

    /// Converts one SensorKit ECG session into its structured Grove graph.
    static func electrocardiogram(
        _ session: SensorKitECGSession,
        reservation: SensorKitRecordReservation,
        payload: Data,
        sidecarPath: String
    ) throws -> SensorKitConversion {
        let record = try SensorKitECGRecord(
            sourceRecordID: reservation.sourceRecordID,
            session: session,
            nativeRecording: try SensorKitNativeRecording(
                title: "Electrocardiogram \(session.startDate.ISO8601Format())",
                format: .nativeRecording,
                payload: .sidecar(path: sidecarPath, bytes: payload),
                admission: .callerAuthorizedOpaquePayload
            )
        )
        return try SensorKitConverter().convert(.electrocardiogram(record), context: reservation.context)
    }
}
