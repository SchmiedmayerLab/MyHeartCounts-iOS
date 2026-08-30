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


/// A SensorKit sample Grove maps to a structured record rather than an opaque payload.
protocol GroveStructuredSensorSample: Sendable {
    /// Whether the record carries a declared native-evidence payload alongside its structured fields.
    static var carriesNativeRecording: Bool { get }

    /// The sample's Grove record, given its producer-assigned identity and native evidence.
    func groveRecord(
        sourceRecordID: SensorKitSourceRecordID,
        nativeRecording: @autoclosure () throws -> SensorKitNativeRecording
    ) throws -> SensorKitRecord

    /// The sample's declared native-evidence encoding, uploaded as the graph's recording document.
    func nativePayload() throws -> Data

    /// Canonical source evidence compared before a retry reuses its coordinate-derived identity.
    func retryEvidence() throws -> Data
}


/// Uploads each sample as a Grove structured graph instead of an opaque recording.
struct UploadStrategyStructured<Sample: SensorKitSampleProtocol>: MHCSensorSampleUploadStrategy
where Sample.SafeRepresentation: GroveStructuredSensorSample {
    func upload(
        _ samples: some RandomAccessCollection<Sample.SafeRepresentation> & Sendable,
        publication: SensorKitBatchPublication,
        for sensor: Sensor<Sample>,
        to standard: MyHeartCountsStandard,
        activity: SensorKitDataFetcher.InProgressActivity
    ) async throws {
        let collection = FirebaseConfiguration.usersCollection
            .document(publication.destination.accountID)
            .collection("HealthObservations_\(sensor.id)")
        activity.updateMessage("Converting \(sensor.displayName)")
        for (recordOrdinal, sample) in samples.enumerated() {
            let reservation = try publication.reserve(
                recordOrdinal: recordOrdinal,
                evidence: sample.retryEvidence()
            )
            var sidecarPath: String?
            var payload = Data()
            if Sample.SafeRepresentation.carriesNativeRecording {
                payload = try sample.nativePayload()
                let filename = "\(reservation.sourceRecordID.value).json"
                sidecarPath = ManagedFileUpload.Category(sensor).remotePath(for: filename)
            }
            let record = try sample.groveRecord(
                sourceRecordID: reservation.sourceRecordID,
                nativeRecording: try SensorKitNativeRecording(
                    title: "\(sensor.displayName) \(reservation.sourceRecordID.value)",
                    format: .nativeRecording,
                    // SAFETY: only evaluated for records that declare they carry native bytes.
                    payload: .sidecar(path: sidecarPath ?? "", bytes: payload),
                    admission: .callerAuthorizedOpaquePayload
                )
            )
            let conversion = try SensorKitGroveRecording.convert(record, reservation: reservation)
            if Sample.SafeRepresentation.carriesNativeRecording {
                let filename = "\(reservation.sourceRecordID.value).json"
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
            }
            try publication.destination.validateCurrentAccount()
            let document = collection.document(reservation.sourceRecordID.value)
            let encoded = try Firestore.Encoder().encode(conversion.bundle)
            try await document.setData(encoded)
        }
    }
}


extension GroveStructuredSensorSample {
    static var carriesNativeRecording: Bool { false }

    func nativePayload() throws -> Data {
        Data()
    }
}
