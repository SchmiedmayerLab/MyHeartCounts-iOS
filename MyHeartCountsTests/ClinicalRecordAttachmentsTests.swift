//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFHIRContract
import HealthKit
@testable import MyHeartCounts
import MyHeartCountsShared
import Synchronization
import Testing
import UniformTypeIdentifiers


/// Clinical records travel with the files HealthKit stores with them, as archives that carry each file beside the Bundle
/// whose records reference it.
@Suite
struct ClinicalRecordAttachmentsTests {
    private static let stepCount = HKQuantityTypeIdentifier.stepCount.rawValue

    /// The records of `count` samples, in sample order.
    private static func records(count: Int) async throws -> [ExchangeRecord] {
        let samples = (0..<count).map(ExchangeHarness.steps)
        let delivery = try await ExchangeHarness().exporter().deliver(samples)
        return try samples.map { try #require(delivery.records[$0.uuid]) }
    }

    /// A new directory, removed once `body` returns.
    private static func withDirectory<Result>(_ body: (URL) async throws -> Result) async throws -> Result {
        let directory = URL.temporaryDirectory.appending(component: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        return try await body(directory)
    }

    /// The record `record` with `recordings`, over the harness's instant.
    private static func archived(
        _ record: ExchangeRecord,
        _ recordings: [UploadBatchArchive.Recording]
    ) -> HealthUploadBatch.ArchivedRecord {
        HealthUploadBatch.ArchivedRecord(record: record, recordings: recordings, timeRange: ExchangeHarness.start..<ExchangeHarness.start)
    }

    /// `contents` as a recording named `name`, in a file in `directory`.
    private static func recording(_ name: String, _ contents: Data, in directory: URL) throws -> UploadBatchArchive.Recording {
        let url = directory.appending(component: name, directoryHint: .notDirectory)
        try contents.write(to: url)
        return UploadBatchArchive.Recording(name: name, fileAt: url)
    }

    @Test
    func clinicalRecordTypesUploadAsArchives() {
        for identifier in [
            HKClinicalTypeIdentifier.allergyRecord, .clinicalNoteRecord, .labResultRecord, .coverageRecord
        ] {
            #expect(ClinicalRecordAttachments.isClinicalRecordType(identifier.rawValue))
            #expect(MyHeartCountsStandard.uploadStrategy(forSampleType: identifier.rawValue) == .clinicalRecordArchive)
        }
        #expect(!ClinicalRecordAttachments.isClinicalRecordType(Self.stepCount))
        #expect(MyHeartCountsStandard.uploadStrategy(forSampleType: Self.stepCount) == .queueLocally)
    }

    /// A file's name is its SHA-256 and its type's extension, else `bin`; it never carries a record identifier.
    @Test
    func aFileIsNamedByItsContent() {
        let digest = Data(repeating: 0xAB, count: 32)
        let hex = String(repeating: "ab", count: 32)
        #expect(ClinicalRecordAttachments.recordingName(sha256: digest, contentType: .pdf) == "\(hex).pdf")
        #expect(ClinicalRecordAttachments.recordingName(sha256: digest, contentType: .data) == "\(hex).bin")
    }

    /// The recordings of a record are the files in its directory, in name order; a record without one has none.
    @Test
    func aRecordsRecordingsAreTheFilesOfItsDirectory() async throws {
        try await Self.withDirectory { attachmentDirectory in
            let sourceID = UUID()
            let directory = ClinicalRecordAttachments.directory(of: sourceID, in: attachmentDirectory)
            #expect(directory.lastPathComponent == sourceID.uuidString.lowercased())
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("b".utf8).write(to: directory.appending(component: "b.pdf"))
            try Data("a".utf8).write(to: directory.appending(component: "a.png"))
            let recordings = try ClinicalRecordAttachments.recordings(of: sourceID, in: attachmentDirectory)
            #expect(recordings.map(\.name) == ["a.png", "b.pdf"])
            #expect(recordings.first?.source == .file(directory.appending(component: "a.png", directoryHint: .notDirectory)))
            #expect(try ClinicalRecordAttachments.recordings(of: UUID(), in: attachmentDirectory).isEmpty)
        }
    }

    /// Each Bundle leaves as an archive that carries exactly the files its own records reference, under the name its
    /// Provenances give it.
    @Test
    func eachArchiveCarriesTheFilesOfItsOwnRecords() async throws {
        let records = try await Self.records(count: 3)
        let staged = Mutex<[(name: String, contents: Data)]>([])
        try await Self.withDirectory { directory in
            let first = try Self.recording("first.pdf", Data("%PDF first".utf8), in: directory)
            let shared = try Self.recording("shared.png", Data(repeating: 0x7F, count: 3_000), in: directory)
            let last = try Self.recording("last.pdf", Data("%PDF last".utf8), in: directory)
            try await HealthUploadBatch.stageArchives(
                [Self.archived(records[0], [first, shared]), Self.archived(records[1], []), Self.archived(records[2], [shared, last])],
                sampleType: Self.stepCount,
                packedAt: ExchangeHarness.start,
                recordsPerPass: 2,
                stage: { url in
                    let contents = try Data(contentsOf: url)
                    staged.withLock { $0.append((url.lastPathComponent, contents)) }
                },
                stageUnreadable: { url in
                    Issue.record("Unexpected unreadable object \(url.lastPathComponent)")
                }
            )
        }
        let archives = staged.withLock { $0 }
        try #require(archives.count == 2)
        let readers = try archives.map { try UploadBatchArchive.Reader($0.contents) }
        #expect(readers.map(\.info.source) == [.healthKit, .healthKit])
        #expect(readers.map(\.info.numRecords) == [2, 1])
        #expect(readers[0].recordingPaths == ["recordings/first.pdf", "recordings/shared.png"])
        #expect(readers[1].recordingPaths == ["recordings/shared.png", "recordings/last.pdf"])
        #expect(try readers[1].recording(at: "recordings/last.pdf") == Data("%PDF last".utf8))
        let bundled = try readers.map { try packedRecords(in: $0.bundle()) }
        #expect(bundled.map { $0.map(\.version) } == [[records[0].version, records[1].version], [records[2].version]])
        #expect(archives[1].name == HealthUploadBatch.filename(
            typePrefix: Self.stepCount,
            provenanceFullURLs: [records[2].version.fullURL],
            fileExtension: "zip"
        ))
    }

    /// A record no Bundle can carry leaves through `stageUnreadable`: with files, as an archive of its own that keeps them,
    /// and without, as its compressed bytes.
    @Test
    func anUnreadableRecordKeepsItsFiles() async throws {
        let records = try await Self.records(count: 2)
        let unreadable = Mutex<[(name: String, contents: Data)]>([])
        try await Self.withDirectory { directory in
            let file = try Self.recording("note.pdf", Data("%PDF note".utf8), in: directory)
            try await HealthUploadBatch.stageArchives(
                [Self.archived(records[0], [file]), Self.archived(records[1], [])],
                sampleType: Self.stepCount,
                packedAt: ExchangeHarness.start,
                makeBundle: HealthUploadBatch.failingBundles(alone: Set(records.map(\.version.fullURL))),
                stage: { url in
                    Issue.record("Unexpected archive \(url.lastPathComponent)")
                },
                stageUnreadable: { url in
                    let contents = try Data(contentsOf: url)
                    unreadable.withLock { $0.append((url.lastPathComponent, contents)) }
                }
            )
        }
        let objects = unreadable.withLock { $0 }
        try #require(objects.count == 2)
        #expect(objects[0].name == HealthUploadBatch.filename(
            typePrefix: "unreadable_\(Self.stepCount)",
            provenanceFullURLs: [records[0].version.fullURL],
            fileExtension: "zip"
        ))
        let reader = try UploadBatchArchive.Reader(objects[0].contents)
        #expect(try reader.bundle() == records[0].json)
        #expect(try reader.recording(at: "recordings/note.pdf") == Data("%PDF note".utf8))
        #expect(objects[1].name.hasSuffix(".zstd"))
    }
}
