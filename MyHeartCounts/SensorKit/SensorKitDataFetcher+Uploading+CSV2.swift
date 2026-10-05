//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import GroveFHIRContract
import GroveSensorKit
import GroveSensorKitFHIR
import SensorKit


/// Uploads each wrist-temperature session using Grove's registered tabular representation, skipping sessions Grove refuses.
struct UploadStrategyWristTemperature: MHCSensorSampleUploadStrategy {
    typealias Sample = SRWristTemperatureSession

    func upload(
        _ samples: some RandomAccessCollection<Sample.SafeRepresentation> & Sendable,
        publication: SensorKitBatchPublication,
        for sensor: Sensor<Sample>,
        activity: SensorKitDataFetcher.InProgressActivity
    ) async throws -> ExchangeProducer.Receipt? {
        activity.updateMessage("Writing to CSV")
        var uploads: [SensorKitRecordUpload] = []
        for (recordOrdinal, sample) in samples.enumerated() {
            let recording = try SensorKitRecordRefusal.preparing(record: recordOrdinal, of: sensor, in: publication) {
                try SensorKitTabularRecording(wristTemperature: sample.sample)
            }
            guard let recording else {
                continue
            }
            uploads.append(SensorKitRecordUpload(
                ordinal: recordOrdinal,
                sidecar: SensorKitUploadSidecar(data: recording.data, format: recording.format),
                retryEvidence: recording.retryEvidence
            ) { sourceRecordID, title, sidecarPath in
                guard let sidecarPath else {
                    throw SensorKitRecordError.missingProviderValue("wristTemperature.location")
                }
                return try recording.sensorKitRecord(
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
