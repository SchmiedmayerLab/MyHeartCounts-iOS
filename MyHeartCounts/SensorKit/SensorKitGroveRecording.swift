//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import CryptoKit
import Foundation
import GroveFHIRContract
import GroveSensorKit
import GroveSensorKitFHIR
import ModelsR4
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
        .visits: .fhirResourceArray,
        .onWristState: .fhirResourceArray,
        .deviceUsageReport: .fhirResourceArray,
        .electrocardiogram: .fhirResourceArray,
        .photoplethysmogram: .photoplethysmogramSamples
    ]

    /// The stream's source token in the Grove SensorKit catalog.
    let sourceToken: String
    /// The registry format the stream's upload strategy writes.
    let format: RegisteredRecordingFormat

    var fileExtension: String {
        if format.csvColumns != nil {
            return "csv"
        }
        return format == .photoplethysmogramSamples ? "mhcPPG" : "json"
    }

    init(_ sensor: some AnySensor) throws {
        guard let sourceToken = Self.sourceTokens[sensor.srSensor],
              let format = Self.formats[sensor.srSensor] else {
            throw SensorKitGroveRecordingError.unsupportedSensor(sensor.id)
        }
        guard let entry = SensorKitCatalog.current.entries.first(where: { $0.sourceToken == sourceToken }),
              entry.rawFormats.contains(format) else {
            throw SensorKitGroveRecordingError.unadmittedFormat(sourceToken: sourceToken, format: format)
        }
        self.sourceToken = sourceToken
        self.format = format
    }

    /// Derives the producer-assigned record UUID from the exact payload bytes.
    ///
    /// Grove permits reusing a source record id only while every source byte is unchanged.
    func recordID(for payload: Data, from device: SensorKit.DeviceInfo) -> UUID {
        var hasher = Insecure.SHA1()
        hasher.update(data: Data("\(sourceToken)|\(device.description)|".utf8))
        hasher.update(data: payload)
        return Data(hasher.finalize().prefix(16))
            .withUnsafeBytes { UUID(uuid: $0.load(as: uuid_t.self)) }
            .makeValidV4()
    }
}


enum SensorKitGroveRecordingError: Error {
    case unsupportedSensor(String)
    case unadmittedFormat(sourceToken: String, format: RegisteredRecordingFormat)
    case missingRecordingDocument
}


/// Wraps a SensorKit batch payload into a Grove SensorKit recording document.
enum SensorKitGroveRecording {
    private static let applicationIdentifierSystem: IdentifierSystem =
        "https://myheartcounts.stanford.edu/fhir/sensorkit/application"
    private static let deviceIdentifierSystem: IdentifierSystem =
        "https://myheartcounts.stanford.edu/fhir/sensorkit/sourceDevice"
    private static let graphIdentifierSystem: IdentifierSystem =
        "https://myheartcounts.stanford.edu/fhir/sensorkit/graph"

    static func document( // swiftlint:disable:this function_parameter_count
        payload: Data,
        recordID: UUID,
        stream: SensorKitGroveStream,
        sidecarPath: String,
        title: String,
        device: SensorKit.DeviceInfo,
        effectiveTimeRange: Swift.Range<Date>,
        subject: Reference
    ) throws -> DocumentReference {
        let record = SensorKitRawRecord(
            sourceRecordID: SensorKitSourceRecordID(recordID),
            sourceToken: stream.sourceToken,
            nativeRecording: try SensorKitNativeRecording(
                title: title,
                contentType: stream.format.registeredContentType,
                format: stream.format,
                payload: .sidecar(path: sidecarPath, bytes: payload),
                admission: .callerAuthorizedOpaquePayload
            )
        )
        let conversion = try SensorKitConverter().convert(.raw(record), context: context(for: device, subject: subject))
        guard var document = conversion.recordingDocument else {
            throw SensorKitGroveRecordingError.missingRecordingDocument
        }
        var documentContext = document.context ?? DocumentReferenceContext()
        documentContext.period = Period(
            end: FHIRPrimitive(try DateTime(date: effectiveTimeRange.upperBound)),
            start: FHIRPrimitive(try DateTime(date: effectiveTimeRange.lowerBound))
        )
        document.context = documentContext
        return document
    }

    /// Converts one already-built Grove record into its graph.
    static func convert(
        _ record: SensorKitRecord,
        device: SensorKit.DeviceInfo,
        subject: Reference
    ) throws -> SensorKitConversion {
        try SensorKitConverter().convert(record, context: context(for: device, subject: subject))
    }

    /// Converts one SensorKit ECG session into its structured Grove graph.
    static func electrocardiogram( // swiftlint:disable:this function_parameter_count
        _ session: SensorKitECGSession,
        recordID: UUID,
        payload: Data,
        sidecarPath: String,
        device: SensorKit.DeviceInfo,
        subject: Reference
    ) throws -> SensorKitConversion {
        let record = try SensorKitECGRecord(
            sourceRecordID: SensorKitSourceRecordID(recordID),
            session: session,
            nativeRecording: try SensorKitNativeRecording(
                title: "Electrocardiogram \(session.startDate.ISO8601Format())",
                contentType: RegisteredRecordingFormat.nativeRecording.registeredContentType,
                format: .nativeRecording,
                payload: .sidecar(path: sidecarPath, bytes: payload),
                admission: .callerAuthorizedOpaquePayload
            )
        )
        return try SensorKitConverter().convert(.electrocardiogram(record), context: context(for: device, subject: subject))
    }

    private static func context(for device: SensorKit.DeviceInfo, subject: Reference) throws -> SensorKitConversionContext {
        SensorKitConversionContext(
            subject: subject,
            converter: SensorApplication(
                identifier: try BusinessIdentifier(
                    system: applicationIdentifierSystem,
                    value: "edu.stanford.MyHeartCounts"
                ),
                name: "My Heart Counts",
                version: Bundle.main.appVersion
            ),
            graphIdentifierSystem: graphIdentifierSystem,
            recordingDevice: SensorRecordingDevice(
                identifier: try BusinessIdentifier(
                    system: deviceIdentifierSystem,
                    value: "\(device.productType)|\(device.name)"
                ),
                name: device.name,
                manufacturer: "Apple",
                modelNumber: device.productType
            ),
            sourceTimeZone: .current,
            issuedAt: .now,
            recordedAt: .now,
            linkableIdentifierPolicy: .authorized,
            researchStudies: MyHeartCountsStandard.currentEnrollmentInfo.map {
                [Reference(reference: "ResearchStudy/\($0.studyId)".asFHIRStringPrimitive())]
            } ?? []
        )
    }
}
