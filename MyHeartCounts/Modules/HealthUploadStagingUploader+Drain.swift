//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFHIRContract
import GroveFoundation
import GroveHealthKitFHIR
import ModelsR4
import MyHeartCountsShared


// The drains' liveness rules, numbered as the code below refers to them.
//
// No deterministic failure may leave a chunk claimed: the next drain would claim the same oldest rows again, and a sample
// drain that throws skips the deletion drain. Only transient errors leave a chunk in place: staging I/O,
// `ManagedFileUpload.stage`, cancellation, low power and low memory. Every row of the drain's subject that holds data leaves
// in exactly one staged object, and the rules are functions of the chunk's sorted rows and their stored bytes, so a re-drain
// of the same rows stages the same files under the same names.
//
// 1. On `conflictingNode` or `mixedKinds`, and on no other packer failure, the current Bundle closes and the record starts a
//    fresh packer of its kind, which admits any one valid record. For `conflictingNode`, the second Bundle carries its own
//    body of the node, so both bodies reach the receiver.
// 2. A record that would take a non-empty packer past a cap comes back `deferred`; an empty packer admits a record over the
//    byte cap, which then travels alone.
// 3. A `deferred` record goes into the next Bundle of the same chunk.
// 4. A row that can't be decompressed or validated leaves alone, as its stored bytes, in an `unreadable_` object. A legacy
//    row is valid when its payload is one UTF-8 JSON object, since it is spliced into its kind's array as stored.
// 5. When a Bundle fails to validate, its records are re-packed one per Bundle; a record whose one-record Bundle still fails
//    leaves alone, as rule 4 says.
// 6. Applied first: a row stored under another subject is removed before anything reads its payload, and so is a record
//    naming another subject, as uploads go to the signed-in participant's folder. A record that states no subject, as a
//    retraction read back from bytes, is stated by no one and passes.
// 7. A deletion Grove refuses to retract leaves alone, as a JSON object of its row's stored fields.
extension HealthUploadStagingUploader {
    /// What one chunk of records became: ``packChunk(_:kind:packedAt:makeBundle:makePacker:)``'s result.
    struct PackedChunk {
        /// The Bundles to stage, in packing order.
        var bundles: [ExchangeGraph] = []
        /// The rows whose one-record Bundle still failed (rule 5), which leave as `unreadable_` objects.
        var failedAlone: [UUID] = []
        /// The rows a `mixedSubjects` failure refused (rule 6), which are removed without an upload.
        var otherSubject: [UUID] = []
        /// How many rows each integrity event kind handled.
        var tally: [HealthUploadIntegrityEvent.Kind: Int] = [:]
    }

    /// What one chunk leaves the device as.
    private struct ChunkUpload {
        var bundles: [ExchangeGraph] = []
        /// Staged like the Bundles.
        var legacyFiles: [HealthUploadBatch.UploadObject] = []
        var unreadable: [HealthUploadBatch.UploadObject] = []
        var tally: [HealthUploadIntegrityEvent.Kind: Int] = [:]

        /// Rule 4: `row` leaves alone, as its stored bytes.
        mutating func leaveUnreadable(
            _ row: HealthUploadStaging.PendingSampleRecord,
            sampleType: String,
            fileExtension: String
        ) {
            unreadable.append(.unreadable(row.fhirJson, sampleType: sampleType, fileExtension: fileExtension))
            tally[.unreadable, default: 0] += 1
        }
    }

    /// A deletion Grove refused to retract, as the JSON object it is uploaded as (rule 7).
    ///
    /// It has no `resourceType` member, so no consumer mistakes it for a FHIR resource.
    private struct RefusedDeletion: Encodable {
        struct Identifier: Encodable {
            let system: String
            let value: String
        }

        struct Refusal: Encodable {
            let code: String
            let location: String
        }

        let format = "mhc-healthkit-deletion-v0"
        let sampleType: String
        /// The HealthKit UUID as the governed native identifier, as a retraction target carries it.
        let nativeIdentifier: Identifier
        let subject: Identifier
        let detectedAt: String
        let deletedAfter: String?
        let refusal: Refusal

        init(_ row: HealthUploadStaging.PendingDeletionRecord, subject: FHIRExchangeSubject, reason: HealthKitConversionError) {
            sampleType = row.sampleType
            nativeIdentifier = Identifier(
                system: FHIRExchangeIdentifiers.healthKitNativeRecord.rawValue,
                value: row.sampleId.uuidString.lowercased()
            )
            // A row staged before rows stored a subject is attributed to the drain's.
            self.subject = Identifier(
                system: row.subjectSystem ?? subject.identity.system.rawValue,
                value: row.subjectValue ?? subject.identity.value
            )
            detectedAt = Self.rfc3339(row.timestamp)
            deletedAfter = row.deletedAfter.map(Self.rfc3339)
            let diagnostic = reason.diagnostic
            refusal = Refusal(code: diagnostic.code, location: diagnostic.location)
        }

        /// `date` in UTC, at the millisecond precision the database stores it at.
        private static func rfc3339(_ date: Date) -> String {
            let milliseconds = (date.timeIntervalSince1970 * 1000).rounded()
            let seconds = (milliseconds / 1000).rounded(.down)
            let whole = Date(timeIntervalSince1970: seconds).ISO8601Format()
            return "\(whole.dropLast()).\(String(format: "%03d", Int(milliseconds - seconds * 1000)))Z"
        }
    }

    /// Packs one chunk's records, in order, into Bundles of `kind`, applying rules 1, 2, 3 and 5 and the `mixedSubjects`
    /// branch of rule 6.
    ///
    /// - parameter makePacker: The packer of each Bundle; production packs under the packer's default caps.
    nonisolated static func packChunk( // swiftlint:disable:this function_body_length
        _ records: [(rowID: UUID, record: ExchangeRecord)],
        kind: ExchangeRecord.Kind,
        packedAt: Date,
        makeBundle: HealthUploadBatch.MakeBundle = HealthUploadBatch.packBundle,
        makePacker: (ExchangeRecord.Kind) -> ExchangeBundlePacker = { ExchangeBundlePacker(kind: $0) }
    ) -> PackedChunk {
        var chunk = PackedChunk()
        var packerKind = kind
        var packer = makePacker(kind)
        var packed: [(rowID: UUID, record: ExchangeRecord)] = []

        func closeBundle() {
            guard !packed.isEmpty else {
                return
            }
            do {
                chunk.bundles.append(try makeBundle(packer, packedAt))
            } catch {
                chunk.tally[.bundleValidation, default: 0] += packed.count
                for entry in packed {
                    repackAlone(entry)
                }
            }
            packed.removeAll()
        }

        func repackAlone(_ entry: (rowID: UUID, record: ExchangeRecord)) {
            var alone = makePacker(entry.record.kind)
            do {
                _ = try alone.insert(entry.record)
                chunk.bundles.append(try makeBundle(alone, packedAt))
            } catch {
                chunk.failedAlone.append(entry.rowID)
                chunk.tally[.unreadable, default: 0] += 1
            }
        }

        func startBundle(of kind: ExchangeRecord.Kind, with entry: (rowID: UUID, record: ExchangeRecord)) {
            closeBundle()
            packerKind = kind
            packer = makePacker(kind)
            do {
                _ = try packer.insert(entry.record)
                packed = [entry]
            } catch {
                // A fresh packer of the record's kind holds nothing to refuse it for.
                chunk.failedAlone.append(entry.rowID)
                chunk.tally[.unreadable, default: 0] += 1
            }
        }

        for entry in records {
            do throws(ExchangeBundlePacker.Failure) {
                switch try packer.insert(entry.record) {
                case .inserted:
                    packed.append(entry)
                case .duplicate:
                    break
                case .deferred:
                    startBundle(of: packerKind, with: entry)
                }
            } catch {
                switch error {
                case .conflictingNode:
                    chunk.tally[.conflictingNode, default: 0] += 1
                    startBundle(of: entry.record.kind, with: entry)
                case .mixedKinds:
                    chunk.tally[.mixedKinds, default: 0] += 1
                    startBundle(of: entry.record.kind, with: entry)
                case .mixedSubjects:
                    chunk.otherSubject.append(entry.rowID)
                    chunk.tally[.otherSubject, default: 0] += 1
                }
            }
        }
        closeBundle()
        return chunk
    }

    /// Writes and stages one chunk's files; `stage` takes its Bundles and legacy files, and `stageUnreadable` its
    /// `unreadable_` objects.
    nonisolated private static func stageFiles(
        of upload: ChunkUpload,
        typePrefix: String,
        stage: (URL) async throws -> Void,
        stageUnreadable: (URL) async throws -> Void
    ) async throws {
        for bundle in upload.bundles {
            try Swift::Task.checkCancellation()
            try await HealthUploadBatch.stageFile(bundle, typePrefix: typePrefix, through: stage)
        }
        for file in upload.legacyFiles {
            try Swift::Task.checkCancellation()
            try await HealthUploadBatch.stageFile(file.contents, filename: file.filename, through: stage)
        }
        for object in upload.unreadable {
            try Swift::Task.checkCancellation()
            try await HealthUploadBatch.stageFile(object.contents, filename: object.filename, through: stageUnreadable)
        }
    }
}


// MARK: Samples

extension HealthUploadStagingUploader {
    /// Drains staged samples chunk by chunk, each of one sample type.
    ///
    /// `stage` takes each Bundle and each legacy file, `stageUnreadable` each `unreadable_` object, and only then is the
    /// chunk removed, so a crash anywhere before re-drains the same rows into the same files.
    ///
    /// - parameter subject: The signed-in subject; a row is the subject's when its stored subject equals it, or when it
    ///     has none.
    /// - parameter makeBundle: How a packed Bundle is finished.
    /// - parameter chunkSize: How many rows the next chunk may take, or `nil` while memory is too low to take one.
    /// - parameter integrityEvents: Takes each chunk's integrity events, once the chunk is removed.
    @concurrent
    static func drainPendingSamples( // swiftlint:disable:this function_parameter_count
        from healthUploadStaging: HealthUploadStaging,
        before processingCutoff: Date,
        maximumChunks: Int?,
        subject: FHIRExchangeSubject,
        stage: @Sendable (URL) async throws -> Void,
        stageUnreadable: @Sendable (URL) async throws -> Void,
        makeBundle: HealthUploadBatch.MakeBundle = HealthUploadBatch.packBundle,
        chunkSize: @Sendable () -> Int? = { HealthUploadStagingUploader.drainChunkSize },
        integrityEvents: @Sendable (HealthUploadIntegrityEvent) -> Void = HealthUploadIntegrityEvent.log
    ) async throws -> Bool {
        var drainedChunks = 0
        while maximumChunks.map({ drainedChunks < $0 }) ?? true {
            try Swift::Task.checkCancellation()
            guard !ProcessInfo.processInfo.isLowPowerModeEnabled else {
                return false
            }
            guard let limit = chunkSize() else {
                return false
            }
            guard let chunk = try healthUploadStaging.claimNextSampleDrainChunk(
                before: processingCutoff,
                limit: limit
            ) else {
                return true
            }
            try Swift::Task.checkCancellation()
            guard !ProcessInfo.processInfo.isLowPowerModeEnabled else {
                return false
            }
            let upload = try Self.upload(of: chunk, subject: subject, makeBundle: makeBundle)
            try await Self.stageFiles(of: upload, typePrefix: chunk.sampleType, stage: stage, stageUnreadable: stageUnreadable)
            try healthUploadStaging.remove(chunk)
            HealthUploadIntegrityEvent.report(upload.tally, sampleType: chunk.sampleType, to: integrityEvents)
            drainedChunks += 1
        }
        return true
    }

    /// Whether a legacy payload may be spliced into its kind's array as stored (rule 4): one UTF-8 JSON object.
    ///
    /// Anything else makes the array unparseable or puts a non-resource into it. `JSONSerialization` alone also reads
    /// UTF-16, UTF-32 and a byte order mark, so the payload must start with `{` and hold no NUL byte, which UTF-8 JSON
    /// never contains. It still reads a trailing comma, which none of the encoders that wrote these rows produce.
    nonisolated static func isLegacyElement(_ json: Data) -> Bool {
        let whitespace: Set<UInt8> = [0x20, 0x09, 0x0A, 0x0D]
        return json.first { !whitespace.contains($0) } == UInt8(ascii: "{")
            && !json.contains(0)
            && (try? JSONSerialization.jsonObject(with: json)) is [String: Any]
    }

    /// What `chunk`'s rows leave the device as, by rules 1 to 6.
    nonisolated private static func upload(
        of chunk: HealthUploadStaging.DrainChunk<HealthUploadStaging.PendingSampleRecord>,
        subject: FHIRExchangeSubject,
        makeBundle: HealthUploadBatch.MakeBundle
    ) throws -> ChunkUpload {
        let rows = chunk.rows.sorted {
            $0.sampleId.uuidString.lowercased() < $1.sampleId.uuidString.lowercased()
        }
        var upload = ChunkUpload()
        var records: [(rowID: UUID, record: ExchangeRecord)] = []
        var legacyResources: [Data] = []
        var legacyEventBundles: [Data] = []
        for row in rows {
            // Rule 6, before anything reads the row's payload.
            guard row.isOwned(by: subject) else {
                upload.tally[.otherSubject, default: 0] += 1
                continue
            }
            guard let json = row.decompressedPayload else {
                upload.leaveUnreadable(row, sampleType: chunk.sampleType, fileExtension: "raw")
                continue
            }
            switch row.payloadFormat {
            case .legacyResource, .legacyEventBundle:
                guard Self.isLegacyElement(json) else {
                    upload.leaveUnreadable(row, sampleType: chunk.sampleType, fileExtension: "zstd")
                    continue
                }
                if row.payloadFormat == .legacyResource {
                    legacyResources.append(json)
                } else {
                    legacyEventBundles.append(json)
                }
            case .record:
                guard let record = try? ExchangeRecord(validating: json) else {
                    upload.leaveUnreadable(row, sampleType: chunk.sampleType, fileExtension: "zstd")
                    continue
                }
                guard !record.namesAnotherSubject(than: subject) else {
                    upload.tally[.otherSubject, default: 0] += 1
                    continue
                }
                records.append((rowID: row.id, record: record))
            }
        }
        let packed = packChunk(records, kind: .active, packedAt: .now, makeBundle: makeBundle)
        upload.bundles = packed.bundles
        upload.tally.merge(packed.tally, uniquingKeysWith: +)
        let failedAlone = Set(packed.failedAlone)
        for row in rows where failedAlone.contains(row.id) {
            upload.unreadable.append(.unreadable(row.fhirJson, sampleType: chunk.sampleType, fileExtension: "zstd"))
        }
        upload.legacyFiles = try [legacyResources, legacyEventBundles].compactMap { elements in
            try HealthUploadBatch.UploadObject.legacy(elements, sampleType: chunk.sampleType)
        }
        return upload
    }
}


// MARK: Deletions

extension HealthUploadStagingUploader {
    /// Drains staged deletions chunk by chunk, each of one sample type.
    ///
    /// One exporter call retracts a chunk; `stage` takes its Retraction Bundles, `stageUnreadable` its `unreadable_`
    /// objects, and only then is the chunk removed, so a crash anywhere before re-drains the same rows.
    ///
    /// - parameter subject: The signed-in subject; a row is the subject's when its stored subject equals it, or when it
    ///     has none.
    /// - parameter makeBundle: How a packed Bundle is finished.
    /// - parameter chunkSize: How many rows the next chunk may take, or `nil` while memory is too low to take one.
    /// - parameter retractionOutcomes: The outcome of retracting each of the rows, in row order, under the subject.
    /// - parameter integrityEvents: Takes each chunk's integrity events, once the chunk is removed.
    nonisolated static func drainPendingDeletions( // swiftlint:disable:this function_parameter_count
        from healthUploadStaging: HealthUploadStaging,
        before processingCutoff: Date,
        maximumChunks: Int?,
        subject: FHIRExchangeSubject,
        stage: (URL) async throws -> Void,
        stageUnreadable: (URL) async throws -> Void,
        makeBundle: HealthUploadBatch.MakeBundle = HealthUploadBatch.packBundle,
        chunkSize: @Sendable () -> Int? = { HealthUploadStagingUploader.drainChunkSize },
        retractionOutcomes: @Sendable (
            HealthUploadStaging,
            [HealthUploadStaging.PendingDeletionRecord],
            FHIRExchangeSubject
        ) async throws -> [HealthKitFHIRExporter.Retraction.Outcome] = { try await $0.retractionBatch(for: $1, subject: $2) },
        integrityEvents: @Sendable (HealthUploadIntegrityEvent) -> Void = HealthUploadIntegrityEvent.log
    ) async throws -> Bool {
        var drainedChunks = 0
        while maximumChunks.map({ drainedChunks < $0 }) ?? true {
            try Swift::Task.checkCancellation()
            guard !ProcessInfo.processInfo.isLowPowerModeEnabled else {
                return false
            }
            guard let limit = chunkSize() else {
                return false
            }
            guard let chunk = try healthUploadStaging.fetchNextDrainChunk(
                of: HealthUploadStaging.PendingDeletionRecord.self,
                before: processingCutoff,
                limit: limit
            ) else {
                return true
            }
            guard !ProcessInfo.processInfo.isLowPowerModeEnabled else {
                return false
            }
            let rows = chunk.rows.sorted {
                $0.sampleId.uuidString.lowercased() < $1.sampleId.uuidString.lowercased()
            }
            // Rule 6: another subject's row is never converted.
            let ownRows = rows.filter { $0.isOwned(by: subject) }
            var outcomes: [HealthKitFHIRExporter.Retraction.Outcome] = []
            if !ownRows.isEmpty {
                outcomes = try await retractionOutcomes(healthUploadStaging, ownRows, subject)
            }
            precondition(outcomes.count == ownRows.count, "Every retracted row has one outcome")
            var upload = try Self.upload(of: zip(ownRows, outcomes), sampleType: chunk.sampleType, subject: subject, makeBundle: makeBundle)
            upload.tally[.otherSubject, default: 0] += rows.count - ownRows.count
            try await Self.stageFiles(of: upload, typePrefix: chunk.sampleType, stage: stage, stageUnreadable: stageUnreadable)
            try healthUploadStaging.remove(chunk)
            HealthUploadIntegrityEvent.report(upload.tally, sampleType: chunk.sampleType, to: integrityEvents)
            drainedChunks += 1
        }
        return true
    }

    /// What one chunk's retractions leave the device as, by rules 1, 2, 3, 5, 6 and 7. A deletion with nothing to retract
    /// holds no collected data and leaves nothing.
    nonisolated private static func upload(
        of retractions: some Sequence<(HealthUploadStaging.PendingDeletionRecord, HealthKitFHIRExporter.Retraction.Outcome)>,
        sampleType: String,
        subject: FHIRExchangeSubject,
        makeBundle: HealthUploadBatch.MakeBundle
    ) throws -> ChunkUpload {
        var upload = ChunkUpload()
        var records: [(rowID: UUID, record: ExchangeRecord)] = []
        for (row, outcome) in retractions {
            switch outcome {
            case .record(let record):
                guard !record.namesAnotherSubject(than: subject) else {
                    upload.tally[.otherSubject, default: 0] += 1
                    continue
                }
                records.append((rowID: row.id, record: record))
            case .refused(let reason):
                let object = try HealthUploadBatch.encoder.encode(RefusedDeletion(row, subject: subject, reason: reason))
                upload.unreadable.append(HealthUploadBatch.UploadObject(
                    filename: "unreadable_\(sampleType)_\(HealthUploadBatch.digest(of: object)).deletion.zstd",
                    contents: try object.compressed(using: Zstd.self)
                ))
                upload.tally[.retractionRefused, default: 0] += 1
            case .nothingToRetract:
                break
            }
        }
        let packed = packChunk(records, kind: .retraction, packedAt: .now, makeBundle: makeBundle)
        upload.bundles = packed.bundles
        upload.tally.merge(packed.tally, uniquingKeysWith: +)
        // A deletion row stores no payload, so what leaves here is the retraction itself.
        let failedAlone = Set(packed.failedAlone)
        for (_, record) in records.filter({ failedAlone.contains($0.rowID) }) {
            upload.unreadable.append(try .unreadable(record, sampleType: sampleType))
        }
        return upload
    }
}


extension ExchangeRecord {
    /// Whether the record states a subject, and another one than `subject`; a record that states none is stated by no one.
    fileprivate func namesAnotherSubject(than subject: FHIRExchangeSubject) -> Bool {
        self.subject.map { !subject.isNamed(by: $0) } ?? false
    }
}


extension ExchangeGraph {
    /// The fullUrls of the Bundle's Provenances, one per record, which name the Bundle's upload file.
    var provenanceFullURLs: [String] {
        (bundle.entry ?? []).compactMap { entry in
            guard case .provenance = entry.resource else {
                return nil
            }
            return entry.fullUrl?.value?.url.absoluteString
        }
    }
}
