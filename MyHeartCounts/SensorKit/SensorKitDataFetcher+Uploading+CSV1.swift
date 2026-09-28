//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import GroveSensorKit
import GroveSensorKitFHIR


/// Uploads one fetched batch using its Grove-owned registered tabular representation.
///
/// The whole batch is one record, so a batch Grove refuses is skipped as a whole.
struct UploadStrategyCSVFile<Sample: SensorKitSampleProtocol>: MHCSensorSampleUploadStrategy
where Sample.SafeRepresentation: SensorKitTabularSample {
    func upload(
        _ samples: some RandomAccessCollection<Sample.SafeRepresentation> & Sendable,
        publication: SensorKitBatchPublication,
        for sensor: Sensor<Sample>,
        to standard: MyHeartCountsStandard,
        activity: SensorKitDataFetcher.InProgressActivity
    ) async throws {
        guard !samples.isEmpty else {
            return
        }
        activity.updateMessage("Writing to CSV")
        do {
            let recording = try SensorKitRecordRefusal.refusing {
                try SensorKitTabularRecording(
                    samples: Array(samples),
                    deviceProductType: publication.info.device.productType
                )
            }
            try await upload(
                sidecar: SensorKitUploadSidecar(data: recording.data, format: recording.format),
                retryEvidence: recording.retryEvidence,
                for: sensor,
                publication: publication,
                to: standard,
                activity: activity
            ) { sourceRecordID, title, sidecarPath in
                guard let sidecarPath else {
                    throw SensorKitRecordError.missingProviderValue("tabular.location")
                }
                return try recording.sensorKitRecord(
                    sourceRecordID: sourceRecordID,
                    title: title,
                    location: .sidecar(path: sidecarPath),
                    admission: .callerAuthorizedOpaquePayload
                )
            }
        } catch let refusal as SensorKitRecordRefusal {
            refusal.log(for: sensor, recordOrdinal: 0)
        }
    }
}
