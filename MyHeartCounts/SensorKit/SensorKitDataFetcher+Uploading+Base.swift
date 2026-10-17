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


/// The exact bytes of a record's recording, archived beside its graph under the file extension the upload strategy that
/// wrote them names.
struct SensorKitUploadSidecar: Sendable {
    let data: Data
    let fileExtension: String
}


/// One record a batch exports, under its identity.
private struct ExportedRecord {
    /// The record's position in its batch, under which a refusal of the record is logged.
    let ordinal: Int
    /// The record's identity, which names its recording within the batch's archive and enters the archive's name.
    let sourceRecordID: SensorKitSourceRecordID
    /// The exact bytes archived beside the record's graph, if it has any.
    let sidecar: SensorKitUploadSidecar?
    /// The number of the batch's samples the record holds, which the batch's info sums up.
    let sampleCount: Int
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


/// One record an upload strategy prepared from its fetched batch, before the record has its identity.
struct SensorKitRecordUpload {
    typealias MakeRecord = (
        _ sourceRecordID: SensorKitSourceRecordID,
        _ title: String,
        _ sidecarPath: String?
    ) throws -> SensorKitRecord

    /// The record's position in its batch, from which its source-record identity derives.
    let ordinal: Int
    /// The number of the batch's samples the record holds.
    let sampleCount: Int
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
        sampleCount: Int,
        sidecar: SensorKitUploadSidecar?,
        retryEvidence: Data,
        supplementalRetryEvidence: Data? = nil,
        makeRecord: @escaping MakeRecord
    ) {
        self.ordinal = ordinal
        self.sampleCount = sampleCount
        self.sidecar = sidecar
        self.retryEvidence = retryEvidence
        self.supplementalRetryEvidence = supplementalRetryEvidence
        self.makeRecord = makeRecord
    }
}


extension MHCSensorSampleUploadStrategy {
    /// The name of a record's recording within its batch's archive.
    private static func recordingName(of sidecar: SensorKitUploadSidecar, sourceRecordID: SensorKitSourceRecordID) -> String {
        "\(sourceRecordID.value).\(sidecar.fileExtension)"
    }

    /// Archives the records of one batch that Grove exported, logging and leaving out each record it refused.
    ///
    /// - parameter records: The batch's exported records, each with its export outcome.
    /// - returns: The finalized archive's file and the identities of the records it holds, or `nil` if Grove refused
    ///     every record.
    private static func archive(
        _ records: some Sequence<(ExportedRecord, SensorKitFHIRExporter.Export.Outcome)>,
        for sensor: Sensor<Sample>,
        publication: SensorKitBatchPublication
    ) throws -> (file: URL, recordIDs: [UUID])? {
        var archive = try UploadBatchArchive(
            source: .sensorKit,
            sampleTypeId: sensor.id,
            device: publication.info.device.productType
        )
        var recordIDs: [UUID] = []
        for (record, outcome) in records {
            switch outcome {
            case .graph(let graph):
                try archive.addRecord(
                    bundle: graph.json,
                    recording: record.sidecar.map { sidecar in
                        UploadBatchArchive.Recording(
                            name: recordingName(of: sidecar, sourceRecordID: record.sourceRecordID),
                            contents: sidecar.data
                        )
                    },
                    // SensorKit states no time span per record, only one for the batch.
                    timeRange: publication.info.timeRange,
                    sampleCount: record.sampleCount
                )
                recordIDs.append(record.sourceRecordID.uuid)
            case .refused(let reason):
                SensorKitRecordRefusal(underlying: reason).log(for: sensor, recordOrdinal: record.ordinal)
            }
        }
        // An archive that is not finalized removes its file.
        guard !recordIDs.isEmpty else {
            return nil
        }
        return (try archive.finalize(), recordIDs)
    }

    /// Publishes the records prepared from one fetched batch through MHC's storage backend.
    ///
    /// Grove owns the exact payload bytes and the FHIR graphs; MHC owns the retry check, the durable file upload and
    /// the acknowledgement boundary. In order:
    /// 1. Each record's bytes are checked against those first seen at its acquisition coordinate, all in one
    ///    transaction of the retry state, so a batch whose content drifted fails before anything is exported.
    /// 2. The records are exported in one call, stating the zone the batch was first published in. A record Grove
    ///    refuses is logged and skipped.
    /// 3. The batch is staged for upload as one ``UploadBatchArchive``: the graphs, verbatim, in `bundles.json`, and each
    ///    sidecar under `recordings/`, at the path relative to the archive's root its graph's DocumentReference states.
    ///    The archive is named by the exported records' identities, so a redelivery overwrites what an earlier attempt
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
            let sidecarPath = upload.sidecar.map {
                UploadBatchArchive.recordingPath(forName: Self.recordingName(of: $0, sourceRecordID: sourceRecordID))
            }
            do {
                records.append(try upload.makeRecord(sourceRecordID, title, sidecarPath))
            } catch {
                SensorKitRecordRefusal(underlying: error).log(for: sensor, recordOrdinal: upload.ordinal)
                continue
            }
            exported.append(ExportedRecord(
                ordinal: upload.ordinal,
                sourceRecordID: sourceRecordID,
                sidecar: upload.sidecar,
                sampleCount: upload.sampleCount
            ))
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
        activity.updateMessage("Submitting for upload")
        guard let archived = try Self.archive(zip(exported, outcomes), for: sensor, publication: publication) else {
            return receipt
        }
        let file = URL.temporaryDirectory.appending(
            path: HealthUploadBatch.filename(typePrefix: sensor.id, identifiers: archived.recordIDs, fileExtension: "zip"),
            directoryHint: .notDirectory
        )
        defer {
            // Staging moves the file; these only remove what staging did not take.
            try? FileManager.default.removeItem(at: archived.file)
            try? FileManager.default.removeItem(at: file)
        }
        try? FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: archived.file, to: file)
        try publication.destination.validateCurrentAccount()
        try await publication.uploader.stageFile(file, ManagedFileUpload.Category(sensor), publication.destination.accountDataGeneration)
        return receipt
    }
}
