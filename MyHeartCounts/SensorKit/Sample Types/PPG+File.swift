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


extension SRPhotoplethysmogramSample {
    struct UploadStrategy: MHCSensorSampleUploadStrategy {
        typealias Sample = SRPhotoplethysmogramSample

        func upload(
            _ samples: consuming some RandomAccessCollection<Sample.SafeRepresentation> & Sendable,
            publication: SensorKitBatchPublication,
            for sensor: Sensor<SRPhotoplethysmogramSample>,
            activity: SensorKitDataFetcher.InProgressActivity
        ) async throws -> ExchangeProducer.Receipt? {
            guard !samples.isEmpty else {
                return nil
            }
            let ppgSamples = Array(samples)
            // The whole batch is one record, so a batch Grove refuses is skipped as a whole.
            let prepared = SensorKitRecordRefusal.preparing(record: 0, of: sensor) {
                try SensorKitPPGRecording(samples: ppgSamples).prepared()
            }
            guard let prepared else {
                return nil
            }
            let upload = SensorKitRecordUpload(
                ordinal: 0,
                sidecar: SensorKitUploadSidecar(data: prepared.data, format: prepared.format),
                retryEvidence: prepared.retryEvidence
            ) { sourceRecordID, title, sidecarPath in
                guard let sidecarPath else {
                    throw SensorKitRecordError.missingProviderValue("photoplethysmogram.location")
                }
                return try prepared.sensorKitRecord(
                    sourceRecordID: sourceRecordID,
                    title: title,
                    location: .sidecar(path: sidecarPath),
                    admission: .callerAuthorizedOpaquePayload
                )
            }
            return try await publish([upload], for: sensor, publication: publication, activity: activity)
        }
    }
}


extension SRPhotoplethysmogramSample: @retroactive Identifiable {
    public var id: UUID {
        var hasher = SensorKitSampleIDHasher()
        hasher.combine(startDate)
        hasher.combine(nanosecondsSinceStart)
        hasher.combine(usage.count)
        hasher.combine(opticalSamples.count)
        hasher.combine(accelerometerSamples.count)
        hasher.combine(temperature?.value)
        return hasher.finalize()
    }
}
