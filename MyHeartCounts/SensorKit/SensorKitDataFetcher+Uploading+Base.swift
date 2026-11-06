//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import CryptoKit
import Foundation
import GroveFHIRContract
import GroveSensorKit
import GroveSensorKitFHIR
import MyHeartCountsShared
import OSLog


/// The exact bytes of a record's recording, archived beside the batch's Bundle under the file extension the upload strategy
/// that wrote them names.
struct SensorKitUploadSidecar: Sendable {
    let data: Data
    let fileExtension: String
}


/// One record a batch exports.
private struct ExportedRecord {
    /// The record's position in its batch, under which a refusal of the record is logged.
    let ordinal: Int
    /// The recording archived beside the batch's Bundle, if the record has any.
    let recording: UploadBatchArchive.Recording?
    /// The number of the batch's samples the record holds, which the batch's info sums up.
    let sampleCount: Int
    /// The time span the record's samples cover, which the batch's info sums up.
    let timeRange: Range<Date>

    /// The record `upload` prepared, whose sidecar is archived as `recording`.
    init(_ upload: SensorKitRecordUpload, recording: UploadBatchArchive.Recording?) {
        ordinal = upload.ordinal
        self.recording = recording
        sampleCount = upload.sampleCount
        timeRange = upload.timeRange
    }
}


/// Grove refused one SensorKit record: preparing or exporting it failed.
///
/// Grove's preparation and export are deterministic, so an exact redelivery refuses identically. The upload
/// strategies therefore skip a refused record and still acknowledge its batch; failing the batch instead would
/// redeliver it forever and block every newer record of the sensor. Every other error (account fence, retry state,
/// staging, Firestore) aborts the batch without acknowledging it, and so does a record that no longer prepares where
/// an earlier attempt prepared it, as that is drift.
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


/// A batch's finalized archive, ready to be staged for upload.
private struct ArchivedBatch {
    /// The finalized batch archive
    let finalizedArchive: UploadBatchArchive.Finalized
    /// The fullUrls of the Provenances of the archive's Bundle, from which its upload name derives.
    let provenanceFullURLs: [String]
}


private enum SensorKitArchiveError: Error {
    /// A batch states a second version of one of its source records, which its one Bundle can't carry.
    case secondRecordVersion
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
    /// The time span the record's samples cover, from the earliest sample's start to the latest sample's end.
    let timeRange: Range<Date>
    /// The exact bytes uploaded beside the batch's Bundle, if the record has any.
    let sidecar: SensorKitUploadSidecar?
    /// The bytes a retry of the record must reproduce: Grove's retry evidence of the record.
    let retryEvidence: Data
    /// What else a retry must reproduce, where the record states more than its `retryEvidence` covers.
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
        timeRange: Range<Date>,
        sidecar: SensorKitUploadSidecar?,
        retryEvidence: Data,
        supplementalRetryEvidence: Data? = nil,
        makeRecord: @escaping MakeRecord
    ) {
        self.ordinal = ordinal
        self.sampleCount = sampleCount
        self.timeRange = timeRange
        self.sidecar = sidecar
        self.retryEvidence = retryEvidence
        self.supplementalRetryEvidence = supplementalRetryEvidence
        self.makeRecord = makeRecord
    }
}


extension MHCSensorSampleUploadStrategy {
    /// A record's recording within its batch's archive, named by its content: changed bytes get a new name, and the name
    /// carries no source record identifier.
    private static func recording(of sidecar: SensorKitUploadSidecar) -> UploadBatchArchive.Recording {
        UploadBatchArchive.Recording(
            name: "\(SHA256.hash(data: sidecar.data).lowercaseHexString).\(sidecar.fileExtension)",
            contents: sidecar.data
        )
    }

    /// Archives the records of one batch that Grove exported, packed into the archive's one Bundle, logging and leaving out
    /// each record it refused.
    ///
    /// - parameter records: The batch's exported records, each with its export outcome.
    /// - parameter packedAt: The Bundle's timestamp, which a redelivery repeats.
    /// - returns: The finalized archive's file, its batch info's JSON and the fullUrls of its Provenances, or `nil` if Grove
    ///     refused every record.
    private static func archive(
        _ records: some Sequence<(ExportedRecord, SensorKitFHIRExporter.Export.Outcome)>,
        for sensor: Sensor<Sample>,
        publication: SensorKitBatchPublication,
        packedAt: Date
    ) throws -> ArchivedBatch? {
        var archive = try UploadBatchArchive(
            source: .sensorKit,
            sampleTypeId: sensor.id,
            device: publication.info.device.productType
        )
        // A batch's archive carries one Bundle, whatever its size.
        var packer = ExchangeBundlePacker(kind: .active, maximumRecords: .max, maximumBytes: .max)
        for (exported, outcome) in records {
            switch outcome {
            case .record(let record):
                guard try packer.add(record) != .deferred else {
                    throw SensorKitArchiveError.secondRecordVersion
                }
                try archive.addRecord(recording: exported.recording, timeRange: exported.timeRange, sampleCount: exported.sampleCount)
            case .refused(let reason):
                SensorKitRecordRefusal(underlying: reason).log(for: sensor, recordOrdinal: exported.ordinal)
            }
        }
        // An archive that is not finalized removes its file.
        guard packer.recordCount > 0 else {
            return nil
        }
        let bundle = try packer.bundle(packedAt: packedAt)
        let finalizedArchive = try archive.finalize(bundle: bundle.json)
        return ArchivedBatch(finalizedArchive: finalizedArchive, provenanceFullURLs: bundle.provenanceFullURLs)
    }

    /// Stages `archived` for upload, under the name its Provenances give it.
    private static func stage(
        _ archived: ArchivedBatch,
        for sensor: Sensor<Sample>,
        publication: SensorKitBatchPublication
    ) async throws {
        defer {
            // Staging moves the file; this only removes what staging did not take.
            try? FileManager.default.removeItem(at: archived.finalizedArchive.url)
        }
        try await HealthUploadBatch.withTemporaryDirectory { directory in
            let file = directory.appending(
                path: HealthUploadBatch.filename(typePrefix: sensor.id, provenanceFullURLs: archived.provenanceFullURLs, fileExtension: "zip"),
                directoryHint: .notDirectory
            )
            try FileManager.default.moveItem(at: archived.finalizedArchive.url, to: file)
            try publication.destination.validateCurrentAccount()
            try await publication.uploader.stageFile(
                at: file,
                category: ManagedFileUpload.Category(sensor),
                accountDataGeneration: publication.destination.accountDataGeneration,
                // The batch info travels with the file, so that the batch can be inspected without downloading it.
                metadata: [UploadBatchArchive.batchInfoMetadataKey: String(decoding: archived.finalizedArchive.batchInfo, as: UTF8.self)]
            )
        }
    }

    /// Publishes the records prepared from one fetched batch through MHC's storage backend.
    ///
    /// Grove owns the exact payload bytes and the FHIR records; MHC owns the retry check, the durable file upload and
    /// the acknowledgement boundary. In order:
    /// 1. Each record's bytes are checked against those first seen at its acquisition coordinate, all in one
    ///    transaction of the retry state, so a batch whose content drifted fails before anything is exported.
    /// 2. The records are exported in one call, stating the zone, the conversion instant, the conversion facts and the devices
    ///    the batch was first published with. A record Grove refuses is logged and skipped.
    /// 3. The batch is staged for upload as one ``UploadBatchArchive``: its one Bundle, verbatim, in `bundle.json`, and each
    ///    sidecar under `recordings/`, at the path relative to the archive's root its DocumentReference states. The Bundle
    ///    states the persisted conversion instant as its timestamp, and the archive is named by its Provenances, so a
    ///    redelivery holds the same entries and overwrites what an earlier attempt uploaded.
    ///
    /// Until the batch is acknowledged, a redelivery repeats every record version.
    ///
    /// - throws: Any error but a refusal aborts the batch, which must then not be acknowledged.
    func publish(
        _ uploads: [SensorKitRecordUpload],
        for sensor: Sensor<Sample>,
        publication: SensorKitBatchPublication,
        activity: SensorKitDataFetcher.InProgressActivity
    ) async throws {
        // Presentation only: the record's identity travels as the typed Identifier, never a label.
        let title = sensor.displayName
        var records: [SensorKitRecord] = []
        var exported: [ExportedRecord] = []
        let sourceRecordIDs = try publication.sourceRecordIDs(of: uploads)
        for (upload, sourceRecordID) in zip(uploads, sourceRecordIDs) {
            let recording = upload.sidecar.map(Self.recording(of:))
            let sidecarPath = recording.map { UploadBatchArchive.recordingPath(forName: $0.name) }
            do {
                records.append(try upload.makeRecord(sourceRecordID, title, sidecarPath))
            } catch {
                SensorKitRecordRefusal(underlying: error).log(for: sensor, recordOrdinal: upload.ordinal)
                continue
            }
            exported.append(ExportedRecord(upload, recording: recording))
        }
        guard !records.isEmpty else {
            return
        }
        let batchFacts = try await publication.batchFacts()
        // One outcome per record, in input order.
        var outcomes: [SensorKitFHIRExporter.Export.Outcome] = []
        try await publication.exporter(stating: batchFacts.conversionFacts).export(
            records,
            sourceTimeZone: batchFacts.timeZone,
            recordingDevice: batchFacts.devices.recordingDevice,
            sourceDevices: batchFacts.devices.sourceDevices,
            at: batchFacts.conversionInstant
        ) { export in
            outcomes.append(export.outcome)
        }
        assert(outcomes.count == exported.count)
        activity.updateMessage("Submitting for upload")
        guard let archived = try Self.archive(
            zip(exported, outcomes),
            for: sensor,
            publication: publication,
            packedAt: batchFacts.conversionInstant
        ) else {
            return
        }
        try await Self.stage(archived, for: sensor, publication: publication)
    }
}


extension UploadBatchArchive {
    /// The key under which an uploaded archive's object metadata carries its batch info, as the JSON `batchinfo.json`
    /// holds, so that the batch can be inspected without downloading the archive.
    ///
    /// Lowercase, as object stores may treat metadata keys as case-insensitive HTTP header names.
    static let batchInfoMetadataKey = "batchinfo"
}


extension Sequence where Element: SensorKitSampleSafeRepresentation {
    /// The time span the samples cover, from the earliest sample's start to the latest sample's end; `nil` if there are
    /// no samples.
    ///
    /// Unlike a fetched batch's `timeRange`, which spans the samples' starts only, this includes the last sample's duration.
    var coveredTimeRange: Range<Date>? {
        var iterator = self.makeIterator()
        guard let fstSampleTimeRange = iterator.next()?.timeRange else {
            return nil
        }
        var lowerBound = fstSampleTimeRange.lowerBound
        var upperBound = fstSampleTimeRange.upperBound
        while let sample = iterator.next() {
            let sampleRange = sample.timeRange
            lowerBound = Swift::min(lowerBound, sampleRange.lowerBound)
            upperBound = Swift::max(upperBound, sampleRange.upperBound)
        }
        return lowerBound..<upperBound
    }
}
