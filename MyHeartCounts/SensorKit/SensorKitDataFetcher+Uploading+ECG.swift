//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
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
            let prepared = try SensorKitRecordRefusal.preparing(record: recordOrdinal, of: sensor, in: publication) {
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
                sidecar: SensorKitUploadSidecar(data: payload, fileExtension: "json"),
                retryEvidence: prepared.retryEvidence,
                supplementalRetryEvidence: session.retryEvidenceSupplement
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


extension SensorKitECGSession {
    /// The session properties an ECG's graph states that Grove's retry evidence of the session omits: its start, sampling
    /// frequency, lead and guidance, each as its exact bits.
    ///
    /// Grove's evidence covers the session's identifier, states and waveform, so without these a redelivery that changed
    /// one of them at the same acquisition coordinate would publish changed content instead of failing as drift.
    var retryEvidenceSupplement: Data {
        var evidence = Data()
        for word in [
            startDate.timeIntervalSince1970.bitPattern,
            frequency.converted(to: .hertz).value.bitPattern,
            UInt64(bitPattern: Int64(lead.rawValue)),
            UInt64(bitPattern: Int64(guidance.rawValue))
        ] {
            withUnsafeBytes(of: word.bigEndian) { evidence.append(contentsOf: $0) }
        }
        return evidence
    }
}
