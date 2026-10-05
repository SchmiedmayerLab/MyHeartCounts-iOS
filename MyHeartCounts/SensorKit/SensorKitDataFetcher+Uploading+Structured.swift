//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import GroveFHIRContract
import GroveSensorKit
import GroveSensorKitFHIR
import SensorKit


/// A SensorKit value for which Grove owns the structured FHIR projection and retry evidence.
protocol GroveStructuredSensorSample: Sendable {
    func grovePreparedRecord() throws -> SensorKitPreparedStructuredRecord
}


/// Uploads each sample using Grove's prepared structured representation, skipping samples Grove refuses.
struct UploadStrategyStructured<Sample: SensorKitSampleProtocol>: MHCSensorSampleUploadStrategy
where Sample.SafeRepresentation: GroveStructuredSensorSample {
    func upload(
        _ samples: some RandomAccessCollection<Sample.SafeRepresentation> & Sendable,
        publication: SensorKitBatchPublication,
        for sensor: Sensor<Sample>,
        activity: SensorKitDataFetcher.InProgressActivity
    ) async throws -> ExchangeProducer.Receipt? {
        activity.updateMessage("Converting \(sensor.displayName)")
        var uploads: [SensorKitRecordUpload] = []
        for (recordOrdinal, sample) in samples.enumerated() {
            guard let prepared = try SensorKitRecordRefusal.preparing(
                record: recordOrdinal,
                of: sensor,
                in: publication,
                sample.grovePreparedRecord
            ) else {
                continue
            }
            uploads.append(SensorKitRecordUpload(
                ordinal: recordOrdinal,
                sidecar: prepared.nativePayload.map { SensorKitUploadSidecar(data: $0, format: .nativeRecording) },
                retryEvidence: prepared.retryEvidence
            ) { sourceRecordID, title, sidecarPath in
                if prepared.nativePayload == nil {
                    return try prepared.sensorKitRecord(sourceRecordID: sourceRecordID)
                }
                guard let sidecarPath else {
                    throw SensorKitRecordError.missingProviderValue("structured.location")
                }
                return try prepared.sensorKitRecord(
                    sourceRecordID: sourceRecordID,
                    title: title,
                    location: .sidecar(path: sidecarPath),
                    admission: .callerAuthorizedOpaquePayload
                )
            })
        }
        return try await publish(uploads, for: sensor, publication: publication, activity: activity)
    }
}


extension SRVisit.SafeRepresentation: GroveStructuredSensorSample {
    func grovePreparedRecord() throws -> SensorKitPreparedStructuredRecord {
        try SensorKitPreparedStructuredRecord(visit: self)
    }
}


extension SensorKitOnWristEventSample: GroveStructuredSensorSample {
    func grovePreparedRecord() throws -> SensorKitPreparedStructuredRecord {
        try SensorKitPreparedStructuredRecord(onWrist: self)
    }
}


extension SRDeviceUsageReport.SafeRepresentation: GroveStructuredSensorSample {
    func grovePreparedRecord() throws -> SensorKitPreparedStructuredRecord {
        try SensorKitPreparedStructuredRecord(deviceUsage: self)
    }
}
