//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import GroveSensorKit
import GroveSensorKitFHIR
import SensorKit


/// Uploads each SensorKit ECG session using Grove's prepared hybrid representation.
struct UploadStrategyECG: MHCSensorSampleUploadStrategy {
    typealias Sample = SRElectrocardiogramSample

    func upload(
        _ samples: some RandomAccessCollection<SensorKitECGSession> & Sendable,
        publication: SensorKitBatchPublication,
        for sensor: Sensor<Sample>,
        to standard: MyHeartCountsStandard,
        activity: SensorKitDataFetcher.InProgressActivity
    ) async throws {
        for (recordOrdinal, session) in samples.enumerated() {
            activity.updateMessage("Converting ECG session")
            let prepared = try SensorKitPreparedStructuredRecord(electrocardiogram: session)
            guard let payload = prepared.nativePayload else {
                throw SensorKitRecordError.missingProviderValue("electrocardiogram.nativePayload")
            }
            try await upload(
                sidecar: SensorKitUploadSidecar(data: payload, format: .nativeRecording),
                retryEvidence: prepared.retryEvidence,
                for: sensor,
                publication: publication,
                to: standard,
                activity: activity,
                recordOrdinal: recordOrdinal
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
            }
        }
    }
}
