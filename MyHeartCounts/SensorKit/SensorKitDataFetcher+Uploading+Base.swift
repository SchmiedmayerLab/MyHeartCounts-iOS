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
import OSLog


struct SensorKitUploadSidecar: Sendable {
    let data: Data
    let format: RegisteredRecordingFormat
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
    /// Builds the record Grove exports, under its identity, its display title and its sidecar's remote path.
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
    private static func filename(of sidecar: SensorKitUploadSidecar, sourceRecordID: SensorKitSourceRecordID) -> String {
        "\(sourceRecordID.value).\(sidecar.format.fileExtension)"
    }

    /// Publishes the records prepared from one fetched batch through MHC's storage backend.
    ///
    /// Grove owns the exact payload bytes and the FHIR graphs; MHC owns the retry check, the durable sidecar upload,
    /// the Firestore destination and the acknowledgement boundary. In order:
    /// 1. Each record's bytes are checked against those first seen at its acquisition coordinate, all in one
    ///    transaction of the retry state, so a batch whose content drifted fails before anything is exported.
    /// 2. The records are exported in one call, stating the zone the batch was first published in. A record Grove
    ///    refuses is logged and skipped.
    /// 3. Each graph's sidecar is staged, then the graph is written to the document its source-record identifier
    ///    names, so a redelivery overwrites what an earlier attempt wrote.
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
        let category = ManagedFileUpload.Category(sensor)
        var records: [SensorKitRecord] = []
        var exported: [ExportedRecord] = []
        let sourceRecordIDs = try publication.sourceRecordIDs(of: uploads)
        for (upload, sourceRecordID) in zip(uploads, sourceRecordIDs) {
            let sidecarPath = upload.sidecar.map { category.remotePath(for: Self.filename(of: $0, sourceRecordID: sourceRecordID)) }
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
        let receipt = try publication.exporter().export(
            records,
            sourceTimeZone: try publication.sourceTimeZone(),
            at: publication.conversionInstant
        ) { export in
            outcomes.append(export.outcome)
        }
        activity.updateMessage("Submitting for upload")
        for (record, outcome) in zip(exported, outcomes) {
            let graph: ExchangeGraph
            switch outcome {
            case .graph(let exportedGraph):
                graph = exportedGraph
            case .refused(let reason):
                SensorKitRecordRefusal(underlying: reason).log(for: sensor, recordOrdinal: record.ordinal)
                continue
            }
            if let sidecar = record.sidecar {
                // Export validated the complete graph before the referenced exact bytes become durably staged.
                // Registered SensorKit payloads remain uncompressed.
                let url = URL.temporaryDirectory.appending(component: Self.filename(of: sidecar, sourceRecordID: record.sourceRecordID))
                try sidecar.data.write(to: url, options: .atomic)
                defer {
                    try? FileManager.default.removeItem(at: url)
                }
                try await publication.uploader.stageSidecar(url, category, publication.destination.accountDataGeneration)
            }
            // Do not introduce a cancellation point here: once a sidecar is durably staged, its one
            // complete Bundle must be persisted before the anchored batch may be acknowledged.
            try await publication.uploader.writeGraph(graph, record.sourceRecordID, sensor.id, publication.destination)
        }
        return receipt
    }
}
