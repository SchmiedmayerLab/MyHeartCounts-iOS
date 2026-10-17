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
import MyHeartCountsShared
import OSLog


/// The exact bytes of a record's recording, archived next to its graph under the file extension the upload strategy that
/// wrote them names.
struct SensorKitUploadSidecar: Sendable {
    let data: Data
    let fileExtension: String
}


/// One record a batch exports, under its identity.
private struct ExportedRecord {
    let ordinal: Int
    let sourceRecordID: SensorKitSourceRecordID
    let sidecar: SensorKitUploadSidecar?
}


/// One record an upload strategy prepared from its fetched batch, before the record has its identity.
struct SensorKitRecordUpload {
    typealias MakeRecord = (
        _ sourceRecordID: SensorKitSourceRecordID,
        _ title: String,
        _ sidecarPath: String?
    ) throws -> SensorKitRecord

    /// The record's position in its batch, from which its source-record identity derives.
    let ordinal: Int
    /// The exact bytes uploaded beside the record's graph, if it has any.
    let sidecar: SensorKitUploadSidecar?
    /// The bytes a retry of the record must reproduce: Grove's retry evidence of the record.
    let retryEvidence: Data
    /// What else a retry must reproduce, where the record's graph states more than its `retryEvidence` covers.
    ///
    /// Checked under a digest of its own, so a pending batch whose `retryEvidence` an earlier build recorded still
    /// matches it.
    let supplementalRetryEvidence: Data?
    /// Builds the record Grove exports, under its identity, its display title and its sidecar's path within the batch's
    /// archive.
    let makeRecord: MakeRecord

    init(
        ordinal: Int,
        sidecar: SensorKitUploadSidecar?,
        retryEvidence: Data,
        supplementalRetryEvidence: Data? = nil,
        makeRecord: @escaping MakeRecord
    ) {
        self.ordinal = ordinal
        self.sidecar = sidecar
        self.retryEvidence = retryEvidence
        self.supplementalRetryEvidence = supplementalRetryEvidence
        self.makeRecord = makeRecord
    }
}


/// Grove refused one SensorKit record: preparing or exporting it failed.
///
/// Grove's preparation and export are deterministic, so an exact redelivery refuses identically. The upload
/// strategies therefore skip a refused record and still acknowledge its batch; failing the batch instead would
/// redeliver it forever and block every newer record of the sensor. Every other error (account fence, retry state,
/// ledger, staging, Firestore) aborts the batch without acknowledging it, and so does a record that no longer
/// prepares where an earlier attempt prepared it, as that is drift.
struct SensorKitRecordRefusal {
    let underlying: any Error

    /// Runs one step of Grove's preparation of the record at `ordinal` of the batch `publication` publishes; a failure
    /// is logged as the record's refusal, and the record is skipped.
    ///
    /// - throws: `FHIRExchangeStateError.retryContentChanged` when the preparation fails for a record an earlier
    ///     attempt prepared: that attempt may have staged or written the record, which a skip would then never
    ///     complete.
    static func preparing<Prepared>(
        record ordinal: Int,
        of sensor: some AnySensor,
        in publication: SensorKitBatchPublication,
        _ prepare: () throws -> Prepared
    ) throws -> Prepared? {
        do {
            return try prepare()
        } catch {
            Self(underlying: error).log(for: sensor, recordOrdinal: ordinal)
            try publication.verifyRefusal(ofRecord: ordinal)
            return nil
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
    /// The path of a record's graph within its batch's archive.
    private static func bundlePath(of sourceRecordID: SensorKitSourceRecordID) -> String {
        "bundles/\(sourceRecordID.value).json"
    }

    /// The path of a record's sidecar within its batch's archive, which its graph's DocumentReference states.
    private static func recordingPath(of sidecar: SensorKitUploadSidecar, sourceRecordID: SensorKitSourceRecordID) -> String {
        "recordings/\(sourceRecordID.value).\(sidecar.fileExtension)"
    }

    /// The entries of a batch's archive, every graph before any recording so that listing the archive shows every record
    /// first, and the identities of the records it holds. A record Grove refused is logged and left out.
    ///
    /// - parameter entries: pairs of ``ExportedRecord``s and their export outcomes.
    private static func archiveEntries(
        _ entries: some Sequence<(ExportedRecord, SensorKitFHIRExporter.Export.Outcome)>,
        for sensor: Sensor<Sample>
    ) -> (entries: [ZipArchive.Entry], recordIDs: [UUID]) {
        var bundles: [ZipArchive.Entry] = []
        var recordings: [ZipArchive.Entry] = []
        var recordIDs: [UUID] = []
        for (record, outcome) in entries {
            switch outcome {
            case .graph(let graph):
                bundles.append(ZipArchive.Entry(path: bundlePath(of: record.sourceRecordID), contents: graph.json))
                if let sidecar = record.sidecar {
                    recordings.append(ZipArchive.Entry(
                        path: recordingPath(of: sidecar, sourceRecordID: record.sourceRecordID),
                        contents: sidecar.data
                    ))
                }
                recordIDs.append(record.sourceRecordID.uuid)
            case .refused(let reason):
                SensorKitRecordRefusal(underlying: reason).log(for: sensor, recordOrdinal: record.ordinal)
            }
        }
        return (bundles + recordings, recordIDs)
    }

    /// Publishes the records prepared from one fetched batch through MHC's storage backend.
    ///
    /// Grove owns the exact payload bytes and the FHIR graphs; MHC owns the retry check, the durable file upload and
    /// the acknowledgement boundary. In order:
    /// 1. Each record's bytes are checked against those first seen at its acquisition coordinate, all in one
    ///    transaction of the retry state, so a batch whose content drifted fails before anything is exported.
    /// 2. The records are exported in one call, stating the zone the batch was first published in. A record Grove
    ///    refuses is logged and skipped.
    /// 3. The batch is staged for upload as one ZIP archive: each graph, verbatim, under `bundles/`, and each sidecar
    ///    under `recordings/`, at the path relative to the archive's root its graph's DocumentReference states. The
    ///    archive is named by the exported records' identities, so a redelivery overwrites what an earlier attempt
    ///    uploaded.
    ///
    /// - returns: The export's receipt, or `nil` when nothing was exported. Release it once the batch is
    ///     acknowledged; until then, a redelivery of the batch restates the same events, byte for byte.
    /// - throws: Any error but a refusal aborts the batch, which must then not be acknowledged.
    func publish(
        _ uploads: [SensorKitRecordUpload],
        for sensor: Sensor<Sample>,
        publication: SensorKitBatchPublication,
        activity: SensorKitDataFetcher.InProgressActivity
    ) async throws -> ExchangeProducer.Receipt? {
        // Presentation only: the record's identity travels as the typed Identifier, never a label.
        let title = sensor.displayName
        var records: [SensorKitRecord] = []
        var exported: [ExportedRecord] = []
        let sourceRecordIDs = try publication.sourceRecordIDs(of: uploads)
        for (upload, sourceRecordID) in zip(uploads, sourceRecordIDs) {
            let sidecarPath = upload.sidecar.map { Self.recordingPath(of: $0, sourceRecordID: sourceRecordID) }
            do {
                records.append(try upload.makeRecord(sourceRecordID, title, sidecarPath))
            } catch {
                SensorKitRecordRefusal(underlying: error).log(for: sensor, recordOrdinal: upload.ordinal)
                continue
            }
            exported.append(ExportedRecord(ordinal: upload.ordinal, sourceRecordID: sourceRecordID, sidecar: upload.sidecar))
        }
        guard !records.isEmpty else {
            return nil
        }
        // One outcome per record, in input order.
        var outcomes: [SensorKitFHIRExporter.Export.Outcome] = []
        let receipt = try await publication.exporter().export(
            records,
            sourceTimeZone: try publication.sourceTimeZone(),
            at: publication.conversionInstant
        ) { export in
            outcomes.append(export.outcome)
        }
        assert(outcomes.count == exported.count)
        let (entries, archivedRecordIDs) = Self.archiveEntries(zip(exported, outcomes), for: sensor)
        guard !archivedRecordIDs.isEmpty else {
            return receipt
        }
        activity.updateMessage("Submitting for upload")
        let file = URL.temporaryDirectory.appending(
            path: HealthUploadBatch.filename(typePrefix: sensor.id, identifiers: archivedRecordIDs, fileExtension: "zip"),
            directoryHint: .notDirectory
        )
        defer {
            // Staging moves the file; this only removes it if staging failed.
            try? FileManager.default.removeItem(at: file)
        }
        var archive = try ZipArchive(writingTo: file)
        for entry in entries {
            try archive.addEntry(
                at: entry.path,
                contents: entry.contents,
                compression: .zstd
            )
        }
        try archive.finalize()
        try publication.destination.validateCurrentAccount()
        try await publication.uploader.stageFile(file, ManagedFileUpload.Category(sensor), publication.destination.accountDataGeneration)
        return receipt
    }
}
