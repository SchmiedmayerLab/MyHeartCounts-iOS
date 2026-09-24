//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import GroveSensorKit
import GroveSensorKitFHIR
import SensorKit


/// Uploads each wrist-temperature session using Grove's registered tabular representation.
struct UploadStrategyWristTemperature: MHCSensorSampleUploadStrategy {
    typealias Sample = SRWristTemperatureSession

    func upload(
        _ samples: some RandomAccessCollection<Sample.SafeRepresentation> & Sendable,
        publication: SensorKitBatchPublication,
        for sensor: Sensor<Sample>,
        to standard: MyHeartCountsStandard,
        activity: SensorKitDataFetcher.InProgressActivity
    ) async throws {
        for (recordOrdinal, sample) in samples.enumerated() {
            activity.updateMessage("Writing to CSV")
            let recording = try SensorKitTabularRecording(wristTemperature: sample.sample)
            try await upload(
                sidecar: SensorKitUploadSidecar(data: recording.data, format: recording.format),
                retryEvidence: recording.retryEvidence,
                for: sensor,
                publication: publication,
                to: standard,
                activity: activity,
                recordOrdinal: recordOrdinal
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
            }
        }
    }
}
