//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

@preconcurrency import FirebaseFirestore
import Foundation
import GroveFirestore
import GroveSensorKit
import GroveSensorKitFHIR
import ModelsR4
import SensorKit


/// Uploads each SensorKit ECG session as a Grove structured ECG graph.
struct UploadStrategyECG: MHCSensorSampleUploadStrategy {
    typealias Sample = SRElectrocardiogramSample

    func upload(
        _ samples: some RandomAccessCollection<SensorKitECGSession> & Sendable,
        batchInfo: SensorKit.BatchInfo,
        for sensor: Sensor<SRElectrocardiogramSample>,
        to standard: MyHeartCountsStandard,
        activity: SensorKitDataFetcher.InProgressActivity
    ) async throws {
        let subject = try await standard.firebaseConfiguration.subjectReference
        let collection = try await standard.firebaseConfiguration.userDocumentReference
            .collection("HealthObservations_\(sensor.id)")
        for session in samples {
            activity.updateMessage("Converting ECG session")
            let payload = try JSONEncoder().encode(session.nativeBatches)
            let recordID = session.groveRecordID
            let filename = "\(recordID.uuidString).json"
            let url = URL.temporaryDirectory.appending(component: filename)
            try payload.write(to: url)
            await standard.uploadSensorKitFile(at: url, for: sensor)

            let conversion = try SensorKitGroveRecording.electrocardiogram(
                session,
                recordID: recordID,
                payload: payload,
                sidecarPath: "\(ManagedFileUpload.Category(sensor).firebasePath)/\(filename)",
                device: batchInfo.device,
                subject: subject
            )
            try await collection.document(recordID.uuidString).setData(from: conversion.bundle)
        }
    }
}


extension SensorKitECGSession {
    struct NativeBatch: Encodable {
        let offsetSeconds: TimeInterval
        let microvolts: [Double]
    }

    /// A producer-assigned identity derived from the session's own fields and samples.
    ///
    /// SensorKit assigns no durable identifier of its own.
    var groveRecordID: UUID {
        var hasher = SensorKitSampleIDHasher()
        hasher.combine(startDate)
        hasher.combine(duration)
        hasher.combine(frequency.value)
        hasher.combine(batches.count)
        for batch in batches {
            hasher.combine(batch.offset)
            hasher.combine(batch.samples.count)
            for sample in batch.samples {
                hasher.combine(sample.voltage.value)
            }
        }
        return hasher.finalize()
    }

    /// The exact per-batch voltages, in the units SensorKit reported them in.
    var nativeBatches: [NativeBatch] {
        batches.map { batch in
            NativeBatch(
                offsetSeconds: batch.offset,
                microvolts: batch.samples.map { $0.voltage.converted(to: .microvolts).value }
            )
        }
    }
}
