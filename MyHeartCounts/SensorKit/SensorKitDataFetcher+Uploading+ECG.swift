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
import SensorKit


/// Uploads each SensorKit ECG session as a Grove structured ECG graph.
struct UploadStrategyECG: MHCSensorSampleUploadStrategy {
    typealias Sample = SRElectrocardiogramSample

    func upload(
        _ samples: some RandomAccessCollection<SensorKitECGSession> & Sendable,
        publication: SensorKitBatchPublication,
        for sensor: Sensor<SRElectrocardiogramSample>,
        to standard: MyHeartCountsStandard,
        activity: SensorKitDataFetcher.InProgressActivity
    ) async throws {
        let collection = FirebaseConfiguration.usersCollection
            .document(publication.destination.accountID)
            .collection("HealthObservations_\(sensor.id)")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        for (recordOrdinal, session) in samples.enumerated() {
            activity.updateMessage("Converting ECG session")
            let payload = try encoder.encode(session.completeNativeEvidence)
            let reservation = try publication.reserve(
                recordOrdinal: recordOrdinal,
                evidence: payload
            )
            let filename = "\(reservation.sourceRecordID.value).json"
            let conversion = try SensorKitGroveRecording.electrocardiogram(
                session,
                reservation: reservation,
                payload: payload,
                sidecarPath: ManagedFileUpload.Category(sensor).remotePath(for: filename)
            )
            let url = URL.temporaryDirectory.appending(component: filename)
            try payload.write(to: url, options: .atomic)
            defer {
                try? FileManager.default.removeItem(at: url)
            }
            try await standard.uploadSensorKitFile(
                at: url,
                for: sensor,
                accountDataGeneration: publication.destination.accountDataGeneration
            )
            try publication.destination.validateCurrentAccount()
            let document = collection.document(reservation.sourceRecordID.value)
            let encoded = try Firestore.Encoder().encode(conversion.bundle)
            try await document.setData(encoded)
        }
    }
}


extension SensorKitECGSession {
    struct NativeEvidence: Encodable {
        let sessionIdentifier: String
        let sessionStates: [Int]
        let batches: [EvidenceBatch]
    }

    struct EvidenceBatch: Encodable {
        struct Sample: Encodable {
            let flags: UInt
            let microvolts: Double
        }

        let offsetSeconds: TimeInterval
        let samples: [Sample]
    }

    /// Native-only evidence required alongside the structured ECG Observation.
    ///
    /// Start time, duration, frequency, lead, guidance, and voltages are represented by the
    /// Observation; this document preserves session identity/state, flags, and batch structure.
    var completeNativeEvidence: NativeEvidence {
        NativeEvidence(
            sessionIdentifier: sessionIdentifier,
            sessionStates: sessionStates.map(\.rawValue),
            batches: batches.map { batch in
                EvidenceBatch(
                    offsetSeconds: batch.offset,
                    samples: batch.samples.map { sample in
                        EvidenceBatch.Sample(
                            flags: sample.flags.rawValue,
                            microvolts: sample.voltage.converted(to: .microvolts).value
                        )
                    }
                )
            }
        )
    }
}
