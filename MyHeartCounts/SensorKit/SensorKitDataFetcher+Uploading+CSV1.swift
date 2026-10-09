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


/// Uploads one fetched batch using its Grove-owned registered tabular representation.
///
/// The whole batch is one record, so a batch Grove refuses is skipped as a whole.
struct UploadStrategyCSVFile<Sample: SensorKitSampleProtocol>: MHCSensorSampleUploadStrategy
where Sample.SafeRepresentation: SensorKitTabularSample {
    func upload(
        _ samples: some RandomAccessCollection<Sample.SafeRepresentation> & Sendable,
        publication: SensorKitBatchPublication,
        for sensor: Sensor<Sample>,
        activity: SensorKitDataFetcher.InProgressActivity
    ) async throws -> ExchangeProducer.Receipt? {
        guard !samples.isEmpty else {
            return nil
        }
        activity.updateMessage("Writing to CSV")
        let recording = try SensorKitRecordRefusal.preparing(record: 0, of: sensor, in: publication) {
            try SensorKitTabularRecording(
                samples: Array(samples),
                deviceProductType: publication.info.device.productType
            )
        }
        guard let recording else {
            return nil
        }
        let upload = SensorKitRecordUpload(
            ordinal: 0,
            sidecar: SensorKitUploadSidecar(data: recording.data, fileExtension: "csv"),
            retryEvidence: recording.retryEvidence
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
        return try await publish([upload], for: sensor, publication: publication, activity: activity)
    }
}
