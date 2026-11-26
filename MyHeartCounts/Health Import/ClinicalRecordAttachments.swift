//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFHIRContract
import GroveHealthKit
import GroveHealthKitFHIR
import HealthKit
import MyHeartCountsShared
import UniformTypeIdentifiers


/// The files HealthKit stores with clinical records, such as a clinical note's PDF, and how they travel: each as a raw
/// entry of the upload archive that carries its record's Bundle, which references it by its path within that archive.
///
/// A batch's files are copied into one directory the batch owns, in one subdirectory per record, named by the record's
/// lowercase UUID; each file is named by its SHA-256 and its type's file extension, the name its attachment document
/// states. Every file of a record is carried, whatever its size: a file HealthKit can't hand over fails the batch, which is
/// then delivered again, rather than leave its record without it.
enum ClinicalRecordAttachments {
    enum Failure: Error {
        /// A clinical record reached an export that has no directory to copy its files into, so they would be lost.
        case noAttachmentDirectory
    }

    /// Whether samples of the type `identifier` names are clinical records, whose uploads carry their files.
    static func isClinicalRecordType(_ identifier: String) -> Bool {
        identifier.hasPrefix("HKClinicalTypeIdentifier")
    }

    /// The name of a file within its archive's `recordings/` directory: its SHA-256 in lowercase hex, and the file
    /// extension its type prefers, else `bin`. Changed bytes get another name, and the name carries no record identifier.
    static func recordingName(sha256: Data, contentType: UTType) -> String {
        "\(sha256.lowercaseHexString).\(contentType.preferredFilenameExtension ?? "bin")"
    }

    /// The directory within `attachmentDirectory` that holds the files of the record whose sample is `sourceID`.
    static func directory(of sourceID: UUID, in attachmentDirectory: URL) -> URL {
        attachmentDirectory.appending(component: sourceID.uuidString.lowercased(), directoryHint: .isDirectory)
    }

    /// Copies every file HealthKit stores with `record` into the record's directory within `attachmentDirectory`, each
    /// under its ``recordingName(sha256:contentType:)``, and returns them as the record's attachments.
    ///
    /// - throws: Any error copying a file, so the batch fails and is delivered again.
    static func copy(
        of record: HKClinicalRecord,
        from healthStore: HKHealthStore,
        into attachmentDirectory: URL
    ) async throws -> [HealthKitFHIRExporter.Record.ClinicalAttachment] {
        let directory = directory(of: record.uuid, in: attachmentDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let copies = try await record.copyAttachments(from: healthStore, into: directory)
        return try copies.map { copy in
            let name = recordingName(sha256: copy.sha256, contentType: copy.attachment.contentType)
            let named = directory.appending(component: name, directoryHint: .notDirectory)
            if FileManager.default.fileExists(atPath: named.path) {
                // Equal bytes: another of the record's files already holds them.
                try FileManager.default.removeItem(at: copy.url)
            } else {
                try FileManager.default.moveItem(at: copy.url, to: named)
            }
            return HealthKitFHIRExporter.Record.ClinicalAttachment(
                copy.attachment,
                payload: .sidecar(
                    path: UploadBatchArchive.recordingPath(forName: name),
                    byteCount: copy.byteCount,
                    sha1: copy.sha1
                )
            )
        }
    }

    /// The files ``copy(of:from:into:)`` left for the record whose sample is `sourceID`, ordered by name, as recordings of
    /// the archive that carries the record; none for a record without files.
    static func recordings(of sourceID: UUID, in attachmentDirectory: URL) throws -> [UploadBatchArchive.Recording] {
        let directory = directory(of: sourceID, in: attachmentDirectory)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return []
        }
        return try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .sorted()
            .map { name in
                UploadBatchArchive.Recording(name: name, fileAt: directory.appending(component: name, directoryHint: .notDirectory))
            }
    }

    /// Exports `samples`, clinical records of the type `sampleType`, with the files HealthKit stores with them, and stages
    /// each Bundle as an ``UploadBatchArchive`` that carries the files its records reference.
    ///
    /// The files live in a directory of the call's own, which is removed once the archives are staged, or the call failed.
    /// The call returns only once every archive is staged, so a batch is acknowledged only once its records and their files
    /// are durably queued for upload.
    static func exportAndStage( // swiftlint:disable:this function_parameter_count
        _ samples: some Collection<some HKSample>,
        sampleType: String,
        at instant: Date,
        healthKit: HealthKit,
        exporter: HealthKitFHIRExporter,
        stage: (URL) async throws -> Void,
        stageUnreadable: (URL) async throws -> Void
    ) async throws -> HealthKitBatchExport {
        var export = HealthKitBatchExport.empty
        try await HealthUploadBatch.withTemporaryDirectory { attachmentDirectory in
            var timeRanges: [UUID: Range<Date>] = [:]
            for sample in samples {
                timeRanges[sample.uuid] = Swift::min(sample.startDate, sample.endDate)..<Swift::max(sample.startDate, sample.endDate)
            }
            var records: [HealthUploadBatch.ArchivedRecord] = []
            export = try await exporter.exportBatch(
                samples,
                at: instant,
                recordProvider: .healthKit(healthKit, attachmentDirectory: attachmentDirectory)
            ) { entry in
                records.append(HealthUploadBatch.ArchivedRecord(
                    record: try entry.exchangeRecord(),
                    recordings: try recordings(of: entry.sourceID, in: attachmentDirectory),
                    timeRange: timeRanges[entry.sourceID] ?? instant..<instant
                ))
            }
            try await HealthUploadBatch.stageArchives(
                records,
                sampleType: sampleType,
                packedAt: instant,
                stage: stage,
                stageUnreadable: stageUnreadable
            )
        }
        return export
    }
}


extension MyHeartCountsStandard {
    /// Uploads one live delivery of clinical records of the type `sampleType`, with the files HealthKit stores with them,
    /// as archives (see ``ClinicalRecordAttachments``), staged for the account `destination` captured.
    static func uploadClinicalRecords(
        _ observations: some Collection<some HealthObservation>,
        sampleType: String,
        at instant: Date,
        destination: FHIRExchangeDestination,
        through dependencies: HealthObservationUploadDependencies
    ) async throws {
        let samples = observations.compactMap { $0 as? HKSample }
        guard samples.count == observations.count else {
            throw HealthObservationUploadError.unsupportedStrategy
        }
        dependencies.logger.notice("Uploading \(samples.count) clinical records of type '\(sampleType)' with their files")
        try destination.validateCurrentAccount()
        let accountDataGeneration = destination.accountDataGeneration
        let exporter = try dependencies.exporter(accountDataGeneration)
        _ = try await HealthKitExportLog.record(.live, samples: HealthKitExportLog.counts(samples), exporter: exporter) {
            try await ClinicalRecordAttachments.exportAndStage(
                samples,
                sampleType: sampleType,
                at: instant,
                healthKit: dependencies.healthKit,
                exporter: exporter
            ) { url in
                try Swift::Task.checkCancellation()
                try destination.validateCurrentAccount()
                try await dependencies.stageFile(url, accountDataGeneration)
            } stageUnreadable: { url in
                try Swift::Task.checkCancellation()
                try destination.validateCurrentAccount()
                try await dependencies.stageUnreadableFile(url, accountDataGeneration)
            }
        }
    }
}
