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


/// Uploads each SensorKit ECG session using Grove's prepared hybrid representation, skipping sessions Grove refuses.
struct UploadStrategyECG: MHCSensorSampleUploadStrategy {
    typealias Sample = SRElectrocardiogramSample

    func upload(
        _ samples: some RandomAccessCollection<SensorKitECGSession> & Sendable,
        publication: SensorKitBatchPublication,
        for sensor: Sensor<Sample>,
        activity: SensorKitDataFetcher.InProgressActivity
    ) async throws -> ExchangeProducer.Receipt? {
        activity.updateMessage("Converting ECG session")
        var uploads: [SensorKitRecordUpload] = []
        for (recordOrdinal, session) in samples.enumerated() {
            let prepared = SensorKitRecordRefusal.preparing(record: recordOrdinal, of: sensor) {
                let prepared = try SensorKitPreparedStructuredRecord(electrocardiogram: session)
                guard let payload = prepared.nativePayload else {
                    throw SensorKitRecordError.missingProviderValue("electrocardiogram.nativePayload")
                }
                return (prepared, payload)
            }
            guard let (prepared, payload) = prepared else {
                continue
            }
            uploads.append(SensorKitRecordUpload(
                ordinal: recordOrdinal,
                sidecar: SensorKitUploadSidecar(data: payload, format: .nativeRecording),
                retryEvidence: prepared.retryEvidence
            ) { sourceRecordID, title, sidecarPath in
                guard let sidecarPath else {
                    throw SensorKitRecordError.missingProviderValue("electrocardiogram.location")
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
