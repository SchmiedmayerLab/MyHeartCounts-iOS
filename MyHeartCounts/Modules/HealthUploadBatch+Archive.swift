//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Algorithms
import Foundation
import GroveFHIRContract
import MyHeartCountsShared


extension HealthUploadBatch {
    /// One record fresh from the exporter, with the recordings its documents reference by their path in its archive.
    struct ArchivedRecord {
        let record: ExchangeRecord
        /// The files the record's documents reference, which its archive carries beside its Bundle.
        let recordings: [UploadBatchArchive.Recording]
        /// The time span the record's sample covers, which the archive's batch info sums up.
        let timeRange: Range<Date>
    }

    /// Packs records fresh from the exporter as ``stage(_:sampleType:packedAt:recordsPerPass:makeBundle:stage:stageUnreadable:)``
    /// does, but hands each Bundle to `stage` as an ``UploadBatchArchive``: the Bundle in `bundle.json`, and every recording
    /// its records reference under `recordings/`, at the path the records state.
    ///
    /// An archive carries only the recordings of the records its Bundle holds. A record no one-record Bundle can carry
    /// leaves through `stageUnreadable`: alone as its compressed bytes, or, with recordings, as an archive of its own, so
    /// that none of its files is left behind.
    ///
    /// - throws: ``PackingError/recordsOfAnotherSubject(count:)`` when one exporter's records name several subjects; the
    ///     batch then stays unacknowledged.
    static func stageArchives(
        _ records: [ArchivedRecord],
        sampleType: String,
        packedAt: Date,
        recordsPerPass: Int = 2_000,
        makeBundle: MakeBundle = packBundle,
        stage: (URL) async throws -> Void,
        stageUnreadable: (URL) async throws -> Void
    ) async throws {
        for pass in records.chunks(ofCount: recordsPerPass) {
            let entries = pass.map { (rowID: UUID(), archived: $0) }
            let packed = HealthUploadStagingUploader.packChunk(
                entries.map { (rowID: $0.rowID, record: $0.archived.record) },
                kind: .active,
                packedAt: packedAt,
                makeBundle: makeBundle
            )
            HealthUploadIntegrityEvent.report(packed.tally, sampleType: sampleType, to: HealthUploadIntegrityEvent.log)
            guard packed.otherSubject.isEmpty else {
                throw PackingError.recordsOfAnotherSubject(count: packed.otherSubject.count)
            }
            for bundle in packed.bundles {
                // A Bundle states each record once; a record the packer took as a duplicate shares its Provenance.
                let provenances = Set(bundle.provenanceFullURLs)
                let members = entries
                    .map(\.archived)
                    .filter { provenances.contains($0.record.version.fullURL) }
                    .uniqued(on: \.record.version.fullURL)
                try await stageArchive(
                    bundle: bundle.json,
                    holding: Array(members),
                    sampleType: sampleType,
                    filename: filename(typePrefix: sampleType, provenanceFullURLs: bundle.provenanceFullURLs, fileExtension: "zip"),
                    through: stage
                )
            }
            let failedAlone = Set(packed.failedAlone)
            for entry in entries where failedAlone.contains(entry.rowID) {
                let record = entry.archived.record
                if entry.archived.recordings.isEmpty {
                    let object = try UploadObject.unreadable(record, sampleType: sampleType)
                    try await stageFile(object.contents, filename: object.filename, through: stageUnreadable)
                } else {
                    try await stageArchive(
                        bundle: record.json,
                        holding: [entry.archived],
                        sampleType: sampleType,
                        filename: filename(
                            typePrefix: "unreadable_\(sampleType)",
                            provenanceFullURLs: [record.version.fullURL],
                            fileExtension: "zip"
                        ),
                        through: stageUnreadable
                    )
                }
            }
        }
    }

    /// Writes the archive of `bundle` and the recordings of `records`, and hands it to `stage` under `filename`.
    private static func stageArchive(
        bundle: Data,
        holding records: [ArchivedRecord],
        sampleType: String,
        filename: String,
        through stage: (URL) async throws -> Void
    ) async throws {
        var archive = try UploadBatchArchive(source: .healthKit, sampleTypeId: sampleType, device: nil)
        for record in records {
            try archive.addRecord(recordings: record.recordings, timeRange: record.timeRange, sampleCount: 1)
        }
        let finalized = try archive.finalize(bundle: bundle)
        defer {
            // Staging moves the file; this only removes what staging did not take.
            try? FileManager.default.removeItem(at: finalized.url)
        }
        try await withTemporaryDirectory { directory in
            let file = directory.appending(path: filename, directoryHint: .notDirectory)
            try FileManager.default.moveItem(at: finalized.url, to: file)
            try await stage(file)
        }
    }
}
