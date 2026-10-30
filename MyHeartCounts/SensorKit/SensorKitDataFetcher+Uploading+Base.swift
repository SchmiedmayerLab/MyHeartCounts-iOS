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
import OSLog


struct SensorKitUploadSidecar: Sendable {
    let data: Data
    let format: RegisteredRecordingFormat
}


/// Grove refused one SensorKit record: preparing or converting it threw.
///
/// Grove's preparation and conversion are deterministic and perform no I/O, so an exact redelivery
/// refuses identically. The upload strategies therefore skip a refused record and still acknowledge
/// its batch; failing the batch instead would redeliver it forever and block every newer record of
/// the sensor. Every other error (account fence, retry ledger, staging, Firestore) aborts the batch
/// without acknowledging it.
struct SensorKitRecordRefusal: Error {
    let underlying: any Error

    /// Runs one step of Grove's preparation, reporting whatever it throws as a refusal of the record.
    static func refusing<Prepared>(_ prepare: () throws -> Prepared) throws -> Prepared {
        do {
            return try prepare()
        } catch {
            throw Self(underlying: error)
        }
    }

    /// Logs the refusal without any record content.
    func log(for sensor: some AnySensor, recordOrdinal: Int) {
        let reason: String = switch underlying {
        case let error as SensorKitConversionError:
            "\(error.diagnostic.code) at \(error.diagnostic.location)"
        case let error as SensorKitRecordError:
            "\(error.diagnostic.code) at \(error.diagnostic.location)"
        default:
            String(reflecting: type(of: underlying))
        }
        logger.warning("Grove refused record #\(recordOrdinal) of SensorKit sensor '\(sensor.id)': \(reason)")
    }
}


extension MHCSensorSampleUploadStrategy {
    /// Publishes one Grove-prepared SensorKit record through MHC's storage backend.
    ///
    /// Grove owns the exact payload bytes and FHIR projection. MHC owns the durable sidecar upload,
    /// Firestore destination, and retry acknowledgement boundary.
    ///
    /// - throws: ``SensorKitRecordRefusal`` if `makeRecord` or Grove's conversion throws; the record's
    ///     reservation is released and nothing was staged or written for it. Any other error aborts the
    ///     batch, which must then not be acknowledged.
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
        let conversion: SensorKitConversion
        do {
            let record = try makeRecord(reservation.sourceRecordID, title, sidecarPath)
            conversion = try SensorKitConverter().convert(record, context: reservation.context)
        } catch {
            publication.release(reservation)
            throw SensorKitRecordRefusal(underlying: error)
        }

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
