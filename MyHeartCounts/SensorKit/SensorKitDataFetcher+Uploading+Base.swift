//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

@preconcurrency import FirebaseFirestore
import Foundation
import GroveFHIRContract
import GroveFirestore
import GroveSensorKit
import GroveSensorKitFHIR


struct SensorKitUploadSidecar: Sendable {
    let data: Data
    let format: RegisteredRecordingFormat
}


extension MHCSensorSampleUploadStrategy {
    /// Publishes one Grove-prepared SensorKit record through MHC's storage backend.
    ///
    /// Grove owns the exact payload bytes and FHIR projection. MHC owns the durable sidecar upload,
    /// Firestore destination, and retry acknowledgement boundary.
    func upload( // swiftlint:disable:this function_parameter_count
        sidecar: SensorKitUploadSidecar?,
        retryEvidence: Data,
        for sensor: Sensor<Sample>,
        publication: SensorKitBatchPublication,
        to standard: MyHeartCountsStandard,
        activity: SensorKitDataFetcher.InProgressActivity,
        recordOrdinal: Int = 0,
        makeRecord: (
            _ sourceRecordID: SensorKitSourceRecordID,
            _ title: String,
            _ sidecarPath: String?
        ) throws -> SensorKitRecord
    ) async throws {
        let reservation = try publication.reserve(
            recordOrdinal: recordOrdinal,
            evidence: retryEvidence
        )
        // Presentation only: the record's identity travels as the typed Identifier, never a label.
        let title = sensor.displayName
        let filename = sidecar.map {
            "\(reservation.sourceRecordID.value).\($0.format.fileExtension)"
        }
        let sidecarPath = filename.map {
            ManagedFileUpload.Category(sensor).remotePath(for: $0)
        }
        let record = try makeRecord(reservation.sourceRecordID, title, sidecarPath)
        let conversion = try SensorKitConverter().convert(record, context: reservation.context)

        if let sidecar, let filename {
            // Conversion validates the complete graph before the referenced exact bytes become
            // durably staged. Registered SensorKit payloads remain uncompressed.
            let url = URL.temporaryDirectory.appending(component: filename)
            try sidecar.data.write(to: url, options: .atomic)
            defer {
                try? FileManager.default.removeItem(at: url)
            }
            activity.updateMessage("Submitting for upload")
            try await standard.uploadSensorKitFile(
                at: url,
                for: sensor,
                accountDataGeneration: publication.destination.accountDataGeneration
            )
        }

        // Do not introduce a cancellation point here: once a sidecar is durably staged, its one
        // complete Bundle must be persisted before the anchored batch may be acknowledged.
        let document = try MyHeartCountsStandard.healthObservationDocument(
            forSampleType: sensor.id,
            id: reservation.sourceRecordID.value,
            destination: publication.destination
        )
        let encoded = try Firestore.Encoder().encode(conversion.bundle)
        try await document.setData(encoded)
    }
}
