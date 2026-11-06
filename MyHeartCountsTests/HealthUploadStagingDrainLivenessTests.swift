//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

// swiftlint:disable file_length

import CryptoKit
import Foundation
import GRDB
import GroveFHIRContract
import GroveFoundation
import GroveHealthKit
import GroveHealthKitFHIR
import HealthKit
@testable import MyHeartCounts
import Synchronization
import Testing


/// What drains handed to their closures, in order.
private final class DrainRecording: Sendable {
    typealias RetractionOutcomes = @Sendable (
        HealthUploadStaging,
        [HealthUploadStaging.PendingDeletionRecord],
        FHIRExchangeSubject
    ) async throws -> [HealthKitFHIRExporter.Retraction.Outcome]

    /// One upload object: its file name, and its bytes as the managed upload would keep them.
    struct Object: Equatable, Sendable {
        let name: String
        let contents: Data

        init(file: URL) throws {
            name = file.lastPathComponent
            contents = try Data(contentsOf: file)
        }
    }

    private let stagedObjects = Mutex<[Object]>([])
    private let unreadableObjects = Mutex<[Object]>([])
    private let stagedCategories = Mutex<[ManagedFileUpload.Category]>([])
    private let collectedEvents = Mutex<[HealthUploadIntegrityEvent]>([])

    /// What `stage` took: Bundles, and then legacy files.
    var staged: [Object] {
        stagedObjects.withLock { $0 }
    }

    /// What `stageUnreadable` took.
    var unreadable: [Object] {
        unreadableObjects.withLock { $0 }
    }

    /// The category of each file ``stagedUploads(of:makeBundle:chunkSize:)`` staged, in order.
    var categories: [ManagedFileUpload.Category] {
        stagedCategories.withLock { $0 }
    }

    var events: [HealthUploadIntegrityEvent] {
        collectedEvents.withLock { $0 }
    }

    var stagedJSON: [Data] {
        get throws {
            try staged.map { try $0.contents.decompressed(using: Zstd.self) }
        }
    }

    /// The versions each staged Bundle states, Bundle by Bundle.
    func stagedVersions(kind: ExchangeGraph.Kind = .active) throws -> [[RecordVersion]] {
        try stagedJSON.map { try packedRecords(in: $0, kind: kind).map(\.version) }
    }

    /// Drains every staged sample under `subject`, by default the harness's participant.
    @discardableResult
    func samples(
        of staging: HealthUploadStaging,
        subject: FHIRExchangeSubject? = nil,
        makeBundle: HealthUploadBatch.MakeBundle = HealthUploadBatch.packBundle
    ) async throws -> Self {
        let finished = try await HealthUploadStagingUploader.drainPendingSamples(
            from: staging,
            before: .distantFuture,
            maximumChunks: nil,
            subject: try subject ?? ExchangeHarness.subject,
            stage: { try self.stage($0) },
            stageUnreadable: { try self.stageUnreadable($0) },
            makeBundle: makeBundle,
            integrityEvents: { self.report($0) }
        )
        #expect(finished)
        return self
    }

    /// Drains every staged deletion under `subject`, by default the harness's participant.
    @discardableResult
    func deletions(
        of staging: HealthUploadStaging,
        subject: FHIRExchangeSubject? = nil,
        makeBundle: HealthUploadBatch.MakeBundle = HealthUploadBatch.packBundle,
        retractionOutcomes: RetractionOutcomes = { try await $0.retractionBatch(for: $1, subject: $2) }
    ) async throws -> Self {
        let finished = try await HealthUploadStagingUploader.drainPendingDeletions(
            from: staging,
            before: .distantFuture,
            maximumChunks: nil,
            subject: try subject ?? ExchangeHarness.subject,
            stage: { try self.stage($0) },
            stageUnreadable: { try self.stageUnreadable($0) },
            makeBundle: makeBundle,
            retractionOutcomes: retractionOutcomes,
            integrityEvents: { self.report($0) }
        )
        #expect(finished)
        return self
    }

    /// Drains every staged sample and deletion under the harness's participant, as `_process` does.
    func stagedUploads(
        of staging: HealthUploadStaging,
        makeBundle: HealthUploadBatch.MakeBundle = HealthUploadBatch.packBundle,
        chunkSize: @Sendable () -> Int? = { 1000 }
    ) async throws -> Bool {
        try await HealthUploadStagingUploader.drainStagedUploads(
            from: staging,
            before: .distantFuture,
            maximumChunks: nil,
            subject: try ExchangeHarness.subject,
            makeBundle: makeBundle,
            chunkSize: chunkSize,
            integrityEvents: { self.report($0) }
        ) { file, category in
            self.stagedCategories.withLock { $0.append(category) }
            if category == .unreadableHealthUpload {
                try self.stageUnreadable(file)
            } else {
                try self.stage(file)
            }
        }
    }

    private func stage(_ file: URL) throws {
        let object = try Object(file: file)
        stagedObjects.withLock { $0.append(object) }
    }

    private func stageUnreadable(_ file: URL) throws {
        let object = try Object(file: file)
        unreadableObjects.withLock { $0.append(object) }
    }

    private func report(_ event: HealthUploadIntegrityEvent) {
        collectedEvents.withLock { $0.append(event) }
    }
}


/// No deterministic failure leaves a chunk claimed, and every row of the drain's subject that holds data leaves in exactly
/// one staged object (H29). Failures are forced only through the drains' seams: `makeBundle`, `retractionOutcomes`, and
/// `packChunk` itself.
@Suite
struct HealthUploadStagingDrainLivenessTests {
    typealias PayloadFormat = HealthUploadStaging.PendingSampleRecord.PayloadFormat

    /// A row of another subject than the drain's.
    enum ForeignRow: CaseIterable, Sendable {
        case validRecord
        case corruptRow
        case deletion
    }

    /// The packer's default byte cap, which a drain packs under.
    private static let packerByteCap = 16 << 20
    private static let stepCount = HKQuantityTypeIdentifier.stepCount.rawValue
    private static let changedManufacturer = "Changed Inc."
    /// Every Bundle fails, the one-record Bundles of rule 5 included.
    private static let everyBundleFails: HealthUploadBatch.MakeBundle = { _, _ throws(ExchangeGraphError) in
        throw .invalidEntries("forced")
    }

    /// The default outcomes, with the deletion of `sampleID` refused.
    private static func refusing(_ sampleID: UUID) -> DrainRecording.RetractionOutcomes {
        { staging, rows, subject in
            var outcomes = try await staging.retractionBatch(for: rows, subject: subject)
            let index = try #require(rows.firstIndex { $0.sampleId == sampleID })
            outcomes[index] = .refused(.unregisteredSourceType("forced"))
            return outcomes
        }
    }

    private static func event(_ kind: HealthUploadIntegrityEvent.Kind, rows: Int) -> HealthUploadIntegrityEvent {
        HealthUploadIntegrityEvent(kind: kind, sampleType: stepCount, rowCount: rows)
    }

    /// 24 lowercase hex characters of `data`'s SHA-256: what an upload's file name states of its contents.
    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    /// Stages deletions of `samples`, as the anchored query reports them.
    private static func delete(_ samples: [HKQuantitySample], in staging: HealthUploadStaging) throws {
        try staging.add(samples.map { try HKDeletedObject.make(uuid: $0.uuid) }, ofType: .stepCount, deletedAfter: nil)
    }

    /// Bytes that are no zstd frame.
    private static func corruptPayload() -> Data {
        Data(UUID().uuidString.utf8)
    }

    /// A zstd frame whose damaged descriptor makes its header state a content size of 2^62 bytes: a size that fits in `Int`,
    /// so only a bound keeps it from reaching an allocation, whose failure is a trap.
    private static func frameStatingAnImpossibleSize() -> Data {
        Data([0x28, 0xB5, 0x2F, 0xFD, 0xE0, 0, 0, 0, 0, 0, 0, 0, 0x40]) + corruptPayload()
    }

    /// A payload that decompresses, but to no record.
    private static func invalidPayload() throws -> Data {
        try legacyPayload(resourceType: "Bundle").compressed(using: Zstd.self)
    }

    /// The uncompressed payload of a legacy row.
    private static func legacyPayload(resourceType: String) -> Data {
        Data(#"{"id":"\#(UUID().uuidString)","resourceType":"\#(resourceType)"}"#.utf8)
    }

    /// A row staged before v5, which records no subject.
    private static func legacyRow(_ format: PayloadFormat, storing stored: Data) -> HealthUploadStaging.PendingSampleRecord {
        HealthUploadStaging.PendingSampleRecord(
            id: UUID(),
            timestamp: ExchangeHarness.start,
            sampleType: stepCount,
            sampleId: UUID(),
            fhirJson: stored,
            payloadFormat: format
        )
    }

    private static func record(of row: HealthUploadStaging.PendingSampleRecord) throws -> ExchangeRecord {
        try ExchangeRecord(validating: row.fhirJson.decompressed(using: Zstd.self))
    }

    private static func record(of outcome: HealthKitFHIRExporter.Retraction.Outcome) -> ExchangeRecord? {
        if case .record(let record) = outcome {
            record
        } else {
            nil
        }
    }

    /// The records `samples` convert to, in sample order.
    private static func records(of samples: [HKQuantitySample], by exporter: HealthKitFHIRExporter) async throws -> [ExchangeRecord] {
        let delivery = try await exporter.deliver(samples)
        return try samples.map { try #require(delivery.records[$0.uuid]) }
    }

    private static func retraction(of sample: HKSample, by exporter: HealthKitFHIRExporter) async throws -> ExchangeRecord {
        let deleted = HealthKitDeletedRecord(
            sourceTypeIdentifier: stepCount,
            nativeRecordID: sample.uuid,
            deletedAfter: nil,
            detectedAt: ExchangeHarness.start
        )
        let outcomes = try await exporter.healthKitRetractions(of: [deleted], recordedAt: ExchangeHarness.start)
        let outcome = try #require(outcomes.first)
        return try #require(record(of: outcome))
    }

    /// `records`, each under a row id of its own.
    private static func rows(_ records: [ExchangeRecord]) -> [(rowID: UUID, record: ExchangeRecord)] {
        records.map { (rowID: UUID(), record: $0) }
    }

    private static func entries(in json: Data) throws -> [[String: Any]] {
        let root = try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        return try #require(root["entry"] as? [[String: Any]])
    }

    /// `json` with `change` applied to every resource of `resourceType`.
    private static func changing(
        _ resourceType: String,
        in json: Data,
        _ change: (inout [String: Any]) -> Void
    ) throws -> Data {
        var root = try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        var entries = try #require(root["entry"] as? [[String: Any]])
        for index in entries.indices {
            guard var resource = entries[index]["resource"] as? [String: Any], resource["resourceType"] as? String == resourceType else {
                continue
            }
            change(&resource)
            entries[index]["resource"] = resource
        }
        root["entry"] = entries
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    /// `json` with another body under the fullUrl of each of its Devices, as a canonicalization change inside the staging
    /// window leaves two records (H5).
    private static func withChangedDevices(_ json: Data) throws -> Data {
        try changing("Device", in: json) { $0["manufacturer"] = changedManufacturer }
    }

    /// The manufacturers the Devices of a Bundle state, which tell the two bodies of a node apart.
    private static func manufacturers(in json: Data) throws -> Set<String> {
        Set(try entries(in: json).compactMap { entry in
            let resource = entry["resource"] as? [String: Any]
            return resource?["resourceType"] as? String == "Device" ? resource?["manufacturer"] as? String : nil
        })
    }

    /// The Provenance fullUrls of a Bundle, read without validating it.
    private static func provenanceFullURLs(in json: Data) throws -> [String] {
        try entries(in: json).compactMap { entry in
            let resource = entry["resource"] as? [String: Any]
            return resource?["resourceType"] as? String == "Provenance" ? entry["fullUrl"] as? String : nil
        }
    }

    @Test
    func unreadableObjectsHaveAnUploadCategoryOfTheirOwn() {
        let category = ManagedFileUpload.Category.unreadableHealthUpload
        #expect(category.id == "HealthKitUpload/unreadable")
        #expect(category.firebasePath == "unreadableHealthSamples")
    }

    /// A chunk takes about a quarter of what is available, and a chunk's measured cost never exceeds what is available.
    @Test
    func chunkSizeFollowsAvailableMemory() {
        let mebibyte = 1 << 20
        #expect(HealthUploadStagingUploader.drainChunkSize(availableMemory: 64 * mebibyte) == nil)
        #expect(HealthUploadStagingUploader.drainChunkSize(availableMemory: 255 * mebibyte) == nil)
        #expect(HealthUploadStagingUploader.drainChunkSize(availableMemory: 256 * mebibyte) == 1024)
        #expect(HealthUploadStagingUploader.drainChunkSize(availableMemory: 400 * mebibyte) == 1600)
        #expect(HealthUploadStagingUploader.drainChunkSize(availableMemory: 1024 * mebibyte) == 4096)
        #expect(HealthUploadStagingUploader.drainChunkSize(availableMemory: 8192 * mebibyte) == 10_000)
    }
}


// MARK: Rule 1

extension HealthUploadStagingDrainLivenessTests {
    @Test
    func aConflictingNodeStagesTwoBundlesEachCarryingItsOwnBody() async throws {
        let staging = try await HealthUploadStaging.resolvedForTesting()
        try await staging.add((0..<2).map(ExchangeHarness.steps))
        let rows = try staging.sampleRows()
        let versions = try rows.map { try Self.record(of: $0).version }
        let changed = try Self.withChangedDevices(rows[1].fhirJson.decompressed(using: Zstd.self))
        try staging.replacePayload(of: rows[1], with: try changed.compressed(using: Zstd.self))

        let drain = try await DrainRecording().samples(of: staging)

        #expect(try drain.stagedVersions() == [[versions[0]], [versions[1]]])
        #expect(try drain.stagedJSON.map(Self.manufacturers) == [[], [Self.changedManufacturer]])
        #expect(drain.unreadable.isEmpty)
        #expect(drain.events == [Self.event(.conflictingNode, rows: 1)])
        #expect(try staging.isEmpty)
    }

    /// The retraction drain follows rule 1 too.
    @Test
    func aConflictingRetractionStagesTwoRetractionBundles() async throws {
        let staging = try await HealthUploadStaging.resolvedForTesting()
        try Self.delete((0..<2).map(ExchangeHarness.steps), in: staging)

        let drain = try await DrainRecording().deletions(of: staging, retractionOutcomes: { staging, rows, subject in
            var outcomes = try await staging.retractionBatch(for: rows, subject: subject)
            let record = try #require(Self.record(of: outcomes[1]))
            outcomes[1] = .record(try ExchangeRecord(validating: Self.withChangedDevices(record.json)))
            return outcomes
        })

        #expect(try drain.stagedVersions(kind: .retraction).map(\.count) == [1, 1])
        #expect(try drain.stagedJSON.map(Self.manufacturers) == [[], [Self.changedManufacturer]])
        #expect(drain.unreadable.isEmpty)
        #expect(drain.events == [Self.event(.conflictingNode, rows: 1)])
        #expect(try staging.isEmpty)
    }

    @Test
    func aRetractionAmongActiveRecordsStartsAFreshBundle() async throws {
        let exporter = try ExchangeHarness().exporter()
        let samples = (0..<3).map(ExchangeHarness.steps)
        let records = try await Self.records(of: Array(samples.prefix(2)), by: exporter)
        let retraction = try await Self.retraction(of: samples[2], by: exporter)

        let chunk = HealthUploadStagingUploader.packChunk(
            Self.rows(records + [retraction]),
            kind: .active,
            packedAt: ExchangeHarness.start
        )

        #expect(chunk.bundles.map(\.kind) == [.active, .retraction])
        #expect(try chunk.bundles.map { try $0.records().map(\.version) } == [records.map(\.version), [retraction.version]])
        #expect(chunk.tally == [.mixedKinds: 1])
        #expect(chunk.failedAlone.isEmpty)
        #expect(chunk.otherSubject.isEmpty)
    }

    @Test
    func oneChunkReportsBothCasesOfRule1EachWithItsOwnCount() async throws {
        let exporter = try ExchangeHarness().exporter()
        let samples = (0..<4).map(ExchangeHarness.steps)
        let records = try await Self.records(of: Array(samples.prefix(3)), by: exporter)
        let changed = try ExchangeRecord(validating: Self.withChangedDevices(records[1].json))
        let retraction = try await Self.retraction(of: samples[3], by: exporter)

        let chunk = HealthUploadStagingUploader.packChunk(
            Self.rows([records[0], changed, records[2], retraction]),
            kind: .active,
            packedAt: ExchangeHarness.start
        )

        #expect(chunk.bundles.map(\.kind) == [.active, .active, .active, .retraction])
        let versions = [records[0], changed, records[2], retraction].map { [$0.version] }
        #expect(try chunk.bundles.map { try $0.records().map(\.version) } == versions)
        var events: [HealthUploadIntegrityEvent] = []
        HealthUploadIntegrityEvent.report(chunk.tally, sampleType: Self.stepCount) { events.append($0) }
        #expect(events == [Self.event(.conflictingNode, rows: 2), Self.event(.mixedKinds, rows: 1)])
    }
}


// MARK: Rules 2 and 3

extension HealthUploadStagingDrainLivenessTests {
    /// A drain packs under the packer's default caps, so the record really is that large: this case is slow.
    @Test
    func aRecordOverTheByteCapStagesAlone() async throws {
        let staging = try await HealthUploadStaging.resolvedForTesting()
        try await staging.add((0..<3).map(ExchangeHarness.steps))
        let rows = try staging.sampleRows()
        let versions = try rows.map { try Self.record(of: $0).version }
        let oversized = try Self.changing("Observation", in: rows[1].fhirJson.decompressed(using: Zstd.self)) { observation in
            observation["note"] = [["text": String(repeating: "x", count: Self.packerByteCap)]]
        }
        try staging.replacePayload(of: rows[1], with: try oversized.compressed(using: Zstd.self))

        let drain = try await DrainRecording().samples(of: staging)

        #expect(try drain.stagedJSON.map(Self.provenanceFullURLs) == versions.map { [$0.fullURL] })
        #expect(drain.unreadable.isEmpty)
        #expect(drain.events.isEmpty)
        #expect(try staging.isEmpty)
    }

    /// Rule 2 at the byte cap: an empty packer admits any record, and every next one is deferred. Rules 2 and 3 report nothing.
    @Test
    func aRecordPastTheByteCapTravelsAlone() async throws {
        let records = try await Self.records(of: (0..<3).map(ExchangeHarness.steps), by: try ExchangeHarness().exporter())

        let chunk = HealthUploadStagingUploader.packChunk(
            Self.rows(records),
            kind: .active,
            packedAt: ExchangeHarness.start,
            makePacker: { ExchangeBundlePacker(kind: $0, maximumBytes: 1) }
        )

        #expect(try chunk.bundles.map { try $0.records().map(\.version) } == records.map { [$0.version] })
        #expect(chunk.tally.isEmpty)
        #expect(chunk.failedAlone.isEmpty)
        #expect(chunk.otherSubject.isEmpty)
    }

    /// Rules 2 and 3 at the record cap: a record the full Bundle defers starts the next Bundle of the same chunk.
    @Test
    func aRecordPastTheRecordCapGoesIntoTheNextBundleOfTheChunk() async throws {
        let records = try await Self.records(of: (0..<5).map(ExchangeHarness.steps), by: try ExchangeHarness().exporter())

        let chunk = HealthUploadStagingUploader.packChunk(
            Self.rows(records),
            kind: .active,
            packedAt: ExchangeHarness.start,
            makePacker: { ExchangeBundlePacker(kind: $0, maximumRecords: 2) }
        )

        let versions = records.map(\.version)
        #expect(try chunk.bundles.map { try $0.records().map(\.version) } == [Array(versions[0..<2]), Array(versions[2..<4]), [versions[4]]])
        #expect(chunk.tally.isEmpty)
        #expect(chunk.failedAlone.isEmpty)
        #expect(chunk.otherSubject.isEmpty)
    }

    @Test
    func aSecondVersionGoesIntoTheNextBundleOfTheChunk() async throws {
        let exporter = try ExchangeHarness().exporter()
        let sample = ExchangeHarness.steps(0)
        let first = try #require(try await exporter.deliver([sample]).records[sample.uuid])
        let later = ExchangeHarness.start.addingTimeInterval(60)
        let second = try #require(try await exporter.deliver([sample], at: later).records[sample.uuid])
        #expect(first.version != second.version)
        let other = try #require(try await Self.records(of: [ExchangeHarness.steps(1)], by: exporter).first)

        let chunk = HealthUploadStagingUploader.packChunk(
            Self.rows([first, other, second]),
            kind: .active,
            packedAt: ExchangeHarness.start
        )

        let versions = [[first.version, other.version], [second.version]]
        #expect(try chunk.bundles.map { try $0.records().map(\.version) } == versions)
        #expect(chunk.tally.isEmpty)
        #expect(chunk.failedAlone.isEmpty)
        #expect(chunk.otherSubject.isEmpty)
    }
}


// MARK: Rules 4 and 5

extension HealthUploadStagingDrainLivenessTests {
    @Test
    func aRowThatCannotBeDecompressedStagesOneRawObject() async throws {
        let staging = try await HealthUploadStaging.resolvedForTesting()
        try await staging.add((0..<3).map(ExchangeHarness.steps))
        let rows = try staging.sampleRows()
        let versions = try rows.map { try Self.record(of: $0).version }
        let stored = Self.corruptPayload()
        try staging.replacePayload(of: rows[1], with: stored)

        let drain = try await DrainRecording().samples(of: staging)

        #expect(drain.unreadable.map(\.name) == ["unreadable_\(Self.stepCount)_\(Self.digest(stored)).raw"])
        #expect(drain.unreadable.map(\.contents) == [stored])
        let namesAnUnreadableObject = drain.staged.contains { $0.name.hasPrefix("unreadable_") }
        #expect(!namesAnUnreadableObject)
        #expect(try drain.stagedVersions() == [[versions[0], versions[2]]])
        #expect(drain.events == [Self.event(.unreadable, rows: 1)])
        #expect(try staging.isEmpty)
    }

    /// Rule 4 must hold for a frame stating any size: decompressing it unbounded would trap, and every later drain with it.
    @Test
    func aRowWhoseFrameStatesAnImpossibleSizeStagesOneRawObject() async throws {
        let staging = try await HealthUploadStaging.resolvedForTesting()
        try await staging.add((0..<3).map(ExchangeHarness.steps))
        let rows = try staging.sampleRows()
        let versions = try rows.map { try Self.record(of: $0).version }
        let stored = Self.frameStatingAnImpossibleSize()
        try staging.replacePayload(of: rows[1], with: stored)

        let drain = try await DrainRecording().samples(of: staging)

        #expect(drain.unreadable.map(\.name) == ["unreadable_\(Self.stepCount)_\(Self.digest(stored)).raw"])
        #expect(drain.unreadable.map(\.contents) == [stored])
        #expect(try drain.stagedVersions() == [[versions[0], versions[2]]])
        #expect(drain.events == [Self.event(.unreadable, rows: 1)])
        #expect(try staging.isEmpty)
    }

    @Test
    func aRowThatFailsValidationStagesOneZstdObject() async throws {
        let staging = try await HealthUploadStaging.resolvedForTesting()
        try await staging.add((0..<3).map(ExchangeHarness.steps))
        let rows = try staging.sampleRows()
        let versions = try rows.map { try Self.record(of: $0).version }
        let stored = try Self.invalidPayload()
        try staging.replacePayload(of: rows[1], with: stored)

        let drain = try await DrainRecording().samples(of: staging)

        #expect(drain.unreadable.map(\.name) == ["unreadable_\(Self.stepCount)_\(Self.digest(stored)).zstd"])
        #expect(drain.unreadable.map(\.contents) == [stored])
        #expect(try drain.stagedVersions() == [[versions[0], versions[2]]])
        #expect(drain.events == [Self.event(.unreadable, rows: 1)])
        #expect(try staging.isEmpty)
    }

    @Test(arguments: [PayloadFormat.legacyResource, .legacyEventBundle])
    func aLegacyRowThatCannotBeDecompressedStagesOneRawObject(format: PayloadFormat) async throws {
        let staging = try await HealthUploadStaging.resolvedForTesting()
        let stored = Self.corruptPayload()
        let element = Self.legacyPayload(resourceType: format == .legacyResource ? "Observation" : "Bundle")
        try staging.insertRow(Self.legacyRow(format, storing: stored))
        try staging.insertRow(Self.legacyRow(format, storing: try element.compressed(using: Zstd.self)))

        let drain = try await DrainRecording().samples(of: staging)

        #expect(drain.unreadable.map(\.name) == ["unreadable_\(Self.stepCount)_\(Self.digest(stored)).raw"])
        #expect(drain.unreadable.map(\.contents) == [stored])
        #expect(try drain.stagedJSON == [splicedJSONArray([element])])
        #expect(drain.events == [Self.event(.unreadable, rows: 1)])
        #expect(try staging.isEmpty)
    }

    /// Legacy rows never share a file with records or with the other legacy kind, and their elements travel as stored.
    @Test
    func legacyRowsLeaveAsOneArrayPerKind() async throws {
        let staging = try await HealthUploadStaging.resolvedForTesting()
        try await staging.add([ExchangeHarness.steps(0)])
        let version = try Self.record(of: try #require(try staging.sampleRows().first)).version
        for resourceType in ["Observation", "Observation", "Bundle"] {
            let payload = try Self.legacyPayload(resourceType: resourceType).compressed(using: Zstd.self)
            try staging.insertRow(Self.legacyRow(resourceType == "Bundle" ? .legacyEventBundle : .legacyResource, storing: payload))
        }
        let rows = try staging.sampleRows()
        let arrays = try [PayloadFormat.legacyResource, .legacyEventBundle].map { format in
            splicedJSONArray(try rows.filter { $0.payloadFormat == format }.map { try $0.fhirJson.decompressed(using: Zstd.self) })
        }

        let drain = try await DrainRecording().samples(of: staging)

        let bundle = try #require(try drain.stagedJSON.first)
        #expect(try packedRecords(in: bundle).map(\.version) == [version])
        #expect(Set(try drain.stagedJSON.dropFirst()) == Set(arrays))
        #expect(Set(drain.staged.dropFirst().map(\.name)) == Set(arrays.map { "\(Self.stepCount)_\(Self.digest($0)).json.zstd" }))
        #expect(drain.unreadable.isEmpty)
        #expect(drain.events.isEmpty)
        #expect(try staging.isEmpty)
    }

    @Test
    func aBundleFailureFallsBackToOneRecordPerBundle() async throws {
        let staging = try await HealthUploadStaging.resolvedForTesting()
        try await staging.add((0..<3).map(ExchangeHarness.steps))
        let versions = try staging.sampleRows().map { try Self.record(of: $0).version }

        let drain = try await DrainRecording().samples(of: staging, makeBundle: HealthUploadBatch.failingBundles())

        #expect(try drain.stagedVersions() == versions.map { [$0] })
        #expect(drain.unreadable.isEmpty)
        #expect(drain.events == [Self.event(.bundleValidation, rows: 3)])
        #expect(try staging.isEmpty)
    }

    /// `unreadable` counts the records that still failed alone and the rule 4 rows, once for the chunk.
    @Test
    func aRecordThatFailsAloneStagesOneZstdObject() async throws {
        let staging = try await HealthUploadStaging.resolvedForTesting()
        try await staging.add((0..<4).map(ExchangeHarness.steps))
        let rows = try staging.sampleRows()
        let versions = try rows.map { try Self.record(of: $0).version }
        let corrupt = Self.corruptPayload()
        try staging.replacePayload(of: rows[3], with: corrupt)

        let drain = try await DrainRecording().samples(of: staging, makeBundle: HealthUploadBatch.failingBundles(alone: [versions[1].fullURL]))

        #expect(Dictionary(uniqueKeysWithValues: drain.unreadable.map { ($0.name, $0.contents) }) == [
            "unreadable_\(Self.stepCount)_\(Self.digest(rows[1].fhirJson)).zstd": rows[1].fhirJson,
            "unreadable_\(Self.stepCount)_\(Self.digest(corrupt)).raw": corrupt
        ])
        #expect(try drain.stagedVersions() == [[versions[0]], [versions[2]]])
        #expect(drain.events == [Self.event(.unreadable, rows: 2), Self.event(.bundleValidation, rows: 3)])
        #expect(try staging.isEmpty)
    }

    /// A sample drain that threw would skip the deletion drain, and a chunk left claimed would keep its deletions waiting.
    @Test(arguments: [false, true])
    func aDeletionBehindAFailingSampleChunkStillDrains(corruptRow: Bool) async throws {
        let staging = try await HealthUploadStaging.resolvedForTesting(autoElideUploadsWhenInsertingDeletions: false)
        let samples = (0..<2).map(ExchangeHarness.steps)
        try await staging.add(samples)
        try Self.delete(samples, in: staging)
        if corruptRow {
            try staging.replacePayload(of: try #require(try staging.sampleRows().first), with: Self.corruptPayload())
        }

        let drain = DrainRecording()
        let finished = try await drain.stagedUploads(
            of: staging,
            makeBundle: corruptRow ? HealthUploadBatch.packBundle : Self.everyBundleFails
        )

        #expect(finished)
        let everyBundleFailed = [Self.event(.unreadable, rows: 2), Self.event(.bundleValidation, rows: 2)]
        #expect(drain.events == (corruptRow ? [Self.event(.unreadable, rows: 1)] : everyBundleFailed + everyBundleFailed))
        #expect(drain.categories == (
            corruptRow
                ? [.liveHealthUpload, .unreadableHealthUpload, .healthDeletions]
                : Array(repeating: .unreadableHealthUpload, count: 4)
        ))
        #expect(try staging.isEmpty)
    }

    /// Samples drain first, and every file goes to the category of its kind.
    @Test
    func theDrainsStageEachFileUnderItsCategory() async throws {
        let staging = try await HealthUploadStaging.resolvedForTesting()
        try await staging.add((0..<2).map(ExchangeHarness.steps))
        try staging.replacePayload(of: try #require(try staging.sampleRows().first), with: Self.corruptPayload())
        try Self.delete([ExchangeHarness.steps(2)], in: staging)

        let drain = DrainRecording()
        let finished = try await drain.stagedUploads(of: staging)

        #expect(finished)
        #expect(drain.categories == [.liveHealthUpload, .unreadableHealthUpload, .healthDeletions])
        #expect(drain.staged.count == 2)
        #expect(drain.unreadable.count == 1)
        #expect(try staging.isEmpty)
    }

    /// Low memory is transient: nothing leaves, and the deletion drain doesn't run behind a sample drain that stopped early,
    /// although memory would allow it by then.
    @Test
    func aSampleDrainThatStopsEarlyLeavesTheDeletions() async throws {
        let staging = try await HealthUploadStaging.resolvedForTesting()
        try await staging.add([ExchangeHarness.steps(0)])
        try Self.delete([ExchangeHarness.steps(1)], in: staging)
        let chunks = Mutex(0)

        let drain = DrainRecording()
        let finished = try await drain.stagedUploads(of: staging, chunkSize: {
            chunks.withLock { count in
                count += 1
                return count == 1 ? nil : 1000
            }
        })

        #expect(!finished)
        #expect(drain.categories.isEmpty)
        #expect(chunks.withLock { $0 } == 1)
        #expect(try staging.fetchCount(of: HealthUploadStaging.PendingSampleRecord.self) == 1)
        #expect(try staging.fetchCount(of: HealthUploadStaging.PendingDeletionRecord.self) == 1)
    }

    /// Staging failing is transient, and leaves the chunk claimed and the deletions for the next drain.
    @Test
    func aSampleDrainThatThrowsLeavesTheDeletions() async throws {
        struct StagingFailure: Error {}
        let staging = try await HealthUploadStaging.resolvedForTesting()
        try await staging.add([ExchangeHarness.steps(0)])
        try Self.delete([ExchangeHarness.steps(1)], in: staging)
        let subject = try ExchangeHarness.subject

        await #expect(throws: StagingFailure.self) {
            _ = try await HealthUploadStagingUploader.drainStagedUploads(
                from: staging,
                before: .distantFuture,
                maximumChunks: nil,
                subject: subject,
                chunkSize: { 1000 }
            ) { _, _ in
                throw StagingFailure()
            }
        }

        #expect(try staging.sampleRows().map(\.uploadClaimed) == [true])
        #expect(try staging.fetchCount(of: HealthUploadStaging.PendingDeletionRecord.self) == 1)
    }
}


// MARK: Retraction Drain

extension HealthUploadStagingDrainLivenessTests {
    /// A deletion row stores no payload, so a retraction that still fails alone leaves as its own record's bytes.
    @Test
    func aRetractionThatFailsAloneStagesItsRecord() async throws {
        let staging = try await HealthUploadStaging.resolvedForTesting()
        try Self.delete((0..<3).map(ExchangeHarness.steps), in: staging)
        let subject = try ExchangeHarness.subject
        let rows = try staging.deletionRows()
        let planned = try await staging.retractionBatch(for: rows, subject: subject).map { try #require(Self.record(of: $0)) }
        let doomed = planned[1].version.fullURL
        let converted = Mutex<[HealthKitFHIRExporter.Retraction.Outcome]>([])

        let drain = try await DrainRecording().deletions(
            of: staging,
            makeBundle: HealthUploadBatch.failingBundles(alone: [doomed]),
            retractionOutcomes: { staging, rows, subject in
                let outcomes = try await staging.retractionBatch(for: rows, subject: subject)
                converted.withLock { $0 = outcomes }
                return outcomes
            }
        )

        let outcomes = converted.withLock { $0 }
        let record = try #require(Self.record(of: outcomes[1]))
        #expect(drain.unreadable.map(\.name) == ["unreadable_\(Self.stepCount)_\(Self.digest(Data(doomed.utf8))).zstd"])
        #expect(try drain.unreadable.map { try $0.contents.decompressed(using: Zstd.self) } == [record.json])
        #expect(try drain.stagedVersions(kind: .retraction) == [[planned[0].version], [planned[2].version]])
        #expect(drain.events == [Self.event(.unreadable, rows: 1), Self.event(.bundleValidation, rows: 3)])
        #expect(try staging.isEmpty)
    }

    /// The object holds the row's stored fields, at their stored precision, and the lowercase UUID only as the governed
    /// native identifier. A row staged before v5 states the drain's subject it is attributed to.
    @Test(arguments: [true, false])
    func aRefusedRetractionStagesTheRowsStoredFields(statesEveryField: Bool) async throws {
        let subject = try ExchangeHarness.subject
        let staging = try await HealthUploadStaging.resolvedForTesting()
        let refused = HealthUploadStaging.PendingDeletionRecord(
            id: UUID(),
            timestamp: ExchangeHarness.start.addingTimeInterval(0.25),
            sampleType: Self.stepCount,
            sampleId: UUID(),
            deletedAfter: statesEveryField ? ExchangeHarness.start.addingTimeInterval(-60.5) : nil,
            subjectSystem: statesEveryField ? subject.identity.system.rawValue : nil,
            subjectValue: statesEveryField ? subject.identity.value : nil
        )
        try staging.insertRow(refused)
        try Self.delete([ExchangeHarness.steps(0)], in: staging)

        let drain = try await DrainRecording().deletions(of: staging, retractionOutcomes: Self.refusing(refused.sampleId))

        let object = try #require(drain.unreadable.first)
        let json = try object.contents.decompressed(using: Zstd.self)
        let nativeID = refused.sampleId.uuidString.lowercased()
        let members = [
            statesEveryField ? #""deletedAfter":"2026-08-29T10:38:59.500Z""# : nil,
            #""detectedAt":"2026-08-29T10:40:00.250Z""#,
            #""format":"mhc-healthkit-deletion-v0""#,
            #""nativeIdentifier":{"system":"\#(FHIRExchangeIdentifiers.healthKitNativeRecord.rawValue)","value":"\#(nativeID)"}"#,
            #""refusal":{"code":"mobile-input.unsupported-source-type","location":"HKSample.sampleType"}"#,
            #""sampleType":"\#(Self.stepCount)""#,
            #""subject":{"system":"\#(subject.identity.system.rawValue)","value":"\#(subject.identity.value)"}"#
        ]
        let text = String(decoding: json, as: UTF8.self)
        #expect(text == "{\(members.compactMap { $0 }.joined(separator: ","))}")
        #expect(!text.contains("resourceType"))
        #expect(drain.unreadable.map(\.name) == ["unreadable_\(Self.stepCount)_\(Self.digest(json)).deletion.zstd"])
        #expect(try drain.stagedVersions(kind: .retraction).map(\.count) == [1])
        #expect(drain.events == [Self.event(.retractionRefused, rows: 1)])
        #expect(try staging.isEmpty)
    }

    /// A deletion of a record class Grove does not inventory holds no collected data.
    @Test
    func aDeletionWithNothingToRetractIsRemoved() async throws {
        let staging = try await HealthUploadStaging.resolvedForTesting()
        try staging.insertRow(HealthUploadStaging.PendingDeletionRecord(
            id: UUID(),
            timestamp: ExchangeHarness.start,
            sampleType: "HKNoSuchTypeIdentifier",
            sampleId: UUID(),
            deletedAfter: nil
        ))

        let drain = try await DrainRecording().deletions(of: staging)

        #expect(drain.staged.isEmpty)
        #expect(drain.unreadable.isEmpty)
        #expect(drain.events.isEmpty)
        #expect(try staging.isEmpty)
    }
}


// MARK: Rule 6

extension HealthUploadStagingDrainLivenessTests {
    @Test(arguments: ForeignRow.allCases, [false, true])
    func anotherSubjectsRowIsRemovedAndStagesNothing(_ foreignRow: ForeignRow, besideOwnRows: Bool) async throws {
        let drainSubject = try ExchangeHarness.otherSubject
        let staging = try await HealthUploadStaging.resolvedForTesting()
        switch foreignRow {
        case .validRecord:
            try await staging.add([ExchangeHarness.steps(0)])
        case .corruptRow:
            try await staging.add([ExchangeHarness.steps(0)])
            try staging.replacePayload(of: try #require(try staging.sampleRows().first), with: Self.corruptPayload())
        case .deletion:
            try Self.delete([ExchangeHarness.steps(0)], in: staging)
        }
        staging.testing?.subject = drainSubject
        var ownVersions: [[RecordVersion]] = []
        if besideOwnRows {
            let sample = ExchangeHarness.steps(1)
            try await staging.add([sample])
            try Self.delete([ExchangeHarness.steps(2)], in: staging)
            ownVersions = [[try Self.record(of: try #require(try staging.sampleRows().first { $0.sampleId == sample.uuid })).version]]
        }

        let samples = try await DrainRecording().samples(of: staging, subject: drainSubject)
        let deletions = try await DrainRecording().deletions(of: staging, subject: drainSubject)

        #expect(try samples.stagedVersions() == ownVersions)
        #expect(try deletions.stagedVersions(kind: .retraction).map(\.count) == (besideOwnRows ? [1] : []))
        #expect(samples.unreadable.isEmpty)
        #expect(deletions.unreadable.isEmpty)
        let foreign = [Self.event(.otherSubject, rows: 1)]
        #expect(samples.events == (foreignRow == .deletion ? [] : foreign))
        #expect(deletions.events == (foreignRow == .deletion ? foreign : []))
        #expect(try staging.isEmpty)
    }

    /// The payload contradicts its row, stored under the drain's subject or under none.
    @Test(arguments: [true, false])
    func aRecordNamingAnotherSubjectIsRemoved(storedUnderTheDrainSubject: Bool) async throws {
        let drainSubject = try ExchangeHarness.otherSubject
        let staging = try await HealthUploadStaging.resolvedForTesting()
        try await staging.add([ExchangeHarness.steps(0)])
        try staging.setStoredSubject(
            of: try #require(try staging.sampleRows().first),
            to: storedUnderTheDrainSubject ? drainSubject : nil
        )
        staging.testing?.subject = drainSubject
        let sample = ExchangeHarness.steps(1)
        try await staging.add([sample])
        let own = try #require(try staging.sampleRows().first { $0.sampleId == sample.uuid })

        let drain = try await DrainRecording().samples(of: staging, subject: drainSubject)

        #expect(try drain.stagedVersions() == [[try Self.record(of: own).version]])
        #expect(drain.unreadable.isEmpty)
        #expect(drain.events == [Self.event(.otherSubject, rows: 1)])
        #expect(try staging.isEmpty)
    }

    @Test
    func aRetractionNamingAnotherSubjectIsRemoved() async throws {
        let otherSubject = try ExchangeHarness.otherSubject
        let staging = try await HealthUploadStaging.resolvedForTesting()
        try Self.delete((0..<2).map(ExchangeHarness.steps), in: staging)

        let drain = try await DrainRecording().deletions(of: staging, retractionOutcomes: { staging, rows, _ in
            try await staging.retractionBatch(for: rows, subject: otherSubject)
        })

        #expect(drain.staged.isEmpty)
        #expect(drain.unreadable.isEmpty)
        #expect(drain.events == [Self.event(.otherSubject, rows: 2)])
        #expect(try staging.isEmpty)
    }

    /// The refused record's row comes back for removal, the records around it stay in one Bundle: a fresh packer would only
    /// hide another subject's record.
    @Test
    func mixedSubjectsReturnsTheRefusedRowAndStartsNoFreshPacker() async throws {
        let harness = ExchangeHarness()
        let samples = (0..<3).map(ExchangeHarness.steps)
        let own = try await Self.records(of: [samples[0], samples[2]], by: try harness.exporter())
        let foreign = try await Self.records(of: [samples[1]], by: try harness.exporter(subject: ExchangeHarness.otherSubject))
        let rows = Self.rows([own[0], foreign[0], own[1]])

        let chunk = HealthUploadStagingUploader.packChunk(rows, kind: .active, packedAt: ExchangeHarness.start)

        #expect(try chunk.bundles.map { try $0.records().map(\.version) } == [own.map(\.version)])
        #expect(chunk.otherSubject == [rows[1].rowID])
        #expect(chunk.failedAlone.isEmpty)
        #expect(chunk.tally == [.otherSubject: 1])
    }

    /// A retraction read back from bytes names no one: neither the drain nor the packer takes it for another subject's.
    @Test
    func aRetractionStatingNoSubjectIsStatedByNoOne() async throws {
        let staging = try await HealthUploadStaging.resolvedForTesting()
        try Self.delete((0..<2).map(ExchangeHarness.steps), in: staging)

        let drain = try await DrainRecording().deletions(of: staging, retractionOutcomes: { staging, rows, subject in
            try await staging.retractionBatch(for: rows, subject: subject).map { outcome in
                let readBack = try ExchangeRecord(validating: try #require(Self.record(of: outcome)).json)
                #expect(readBack.subject == nil)
                return .record(readBack)
            }
        })

        #expect(try drain.stagedVersions(kind: .retraction).map(\.count) == [2])
        #expect(drain.unreadable.isEmpty)
        #expect(drain.events.isEmpty)
        #expect(try staging.isEmpty)
    }

    /// A staged row whose record states no subject passes rule 6, and is the drain's to upload.
    @Test
    func aStagedRecordStatingNoSubjectIsKept() async throws {
        let staging = try await HealthUploadStaging.resolvedForTesting()
        let retraction = try await Self.retraction(of: ExchangeHarness.steps(0), by: try ExchangeHarness(identity: staging.stateStore).exporter())
        var row = Self.legacyRow(.record, storing: try retraction.json.compressed(using: Zstd.self))
        row.subjectSystem = try ExchangeHarness.subject.identity.system.rawValue
        row.subjectValue = try ExchangeHarness.subject.identity.value
        try staging.insertRow(row)

        let drain = try await DrainRecording().samples(of: staging)

        #expect(try drain.stagedVersions(kind: .retraction) == [[retraction.version]])
        #expect(drain.unreadable.isEmpty)
        #expect(drain.events == [Self.event(.mixedKinds, rows: 1)])
        #expect(try staging.isEmpty)
    }

    @Test
    func thePackerComparesARecordStatingNoSubjectWithNoOne() async throws {
        let exporter = try ExchangeHarness().exporter()
        let first = try await Self.retraction(of: ExchangeHarness.steps(0), by: exporter)
        let second = try await Self.retraction(of: ExchangeHarness.steps(1), by: exporter)
        let readBack = try ExchangeRecord(validating: second.json)
        #expect(first.subject != nil)
        #expect(readBack.subject == nil)

        let chunk = HealthUploadStagingUploader.packChunk(Self.rows([first, readBack]), kind: .retraction, packedAt: ExchangeHarness.start)

        #expect(try chunk.bundles.map { try $0.records().map(\.version) } == [[first.version, second.version]])
        #expect(chunk.otherSubject.isEmpty)
        #expect(chunk.tally.isEmpty)
    }
}


// MARK: Subject-Aware Staging

extension HealthUploadStagingDrainLivenessTests {
    @Test
    func everyInsertStoresTheStagingSubject() async throws {
        let staging = try await HealthUploadStaging.resolvedForTesting()
        for (index, subject) in [try ExchangeHarness.subject, try ExchangeHarness.otherSubject].enumerated() {
            staging.testing?.subject = subject
            let added = ExchangeHarness.steps(index)
            let deleted = ExchangeHarness.steps(index + 2)
            try await staging.add([added])
            try Self.delete([deleted], in: staging)

            let sample = try #require(try staging.sampleRows().first { $0.sampleId == added.uuid })
            let deletion = try #require(try staging.deletionRows().first { $0.sampleId == deleted.uuid })
            #expect(sample.subjectSystem == subject.identity.system.rawValue)
            #expect(sample.subjectValue == subject.identity.value)
            #expect(deletion.subjectSystem == subject.identity.system.rawValue)
            #expect(deletion.subjectValue == subject.identity.value)
        }
    }

    /// The claimed row is another subject's, so nothing of it leaves: the redelivery is what the drain uploads.
    @Test
    func anotherSubjectsRedeliveryReplacesAClaimedRow() async throws {
        let drainSubject = try ExchangeHarness.otherSubject
        let staging = try await HealthUploadStaging.resolvedForTesting()
        let sample = ExchangeHarness.steps(0)
        try await staging.add([sample], ingestionTimestamp: ExchangeHarness.start)
        let claimed = try #require(try staging.claimNextSampleDrainChunk(before: .distantFuture, limit: 1))
        staging.testing?.subject = drainSubject

        try await staging.add([sample], ingestionTimestamp: ExchangeHarness.start.addingTimeInterval(60))

        let rows = try staging.sampleRows()
        let row = try #require(rows.first)
        #expect(rows.map(\.id) != claimed.rows.map(\.id))
        #expect(rows.map(\.uploadClaimed) == [false])
        #expect(rows.map(\.subjectValue) == [drainSubject.identity.value])
        let drain = try await DrainRecording().samples(of: staging, subject: drainSubject)
        #expect(try drain.stagedVersions() == [[try Self.record(of: row).version]])
        #expect(drain.events.isEmpty)
        #expect(try staging.isEmpty)
    }

    /// A row staged before v5 counts as the same subject's (H17).
    @Test(arguments: [true, false])
    func ownRedeliveryOfAClaimedRowIsSkipped(storedSubject: Bool) async throws {
        let staging = try await HealthUploadStaging.resolvedForTesting()
        let sample = ExchangeHarness.steps(0)
        try await staging.add([sample], ingestionTimestamp: ExchangeHarness.start)
        let claimed = try #require(try staging.claimNextSampleDrainChunk(before: .distantFuture, limit: 1))
        if !storedSubject {
            try staging.setStoredSubject(of: try #require(claimed.rows.first), to: nil)
        }

        try await staging.add([sample], ingestionTimestamp: ExchangeHarness.start.addingTimeInterval(60))

        let rows = try staging.sampleRows()
        #expect(rows.map(\.id) == claimed.rows.map(\.id))
        #expect(rows.map(\.fhirJson) == claimed.rows.map(\.fhirJson))
        #expect(rows.map(\.uploadClaimed) == [true])
        let drain = try await DrainRecording().samples(of: staging)
        #expect(try drain.stagedVersions() == [try claimed.rows.map { try Self.record(of: $0).version }])
        #expect(try staging.isEmpty)
    }

    @Test
    func anotherSubjectsDeletionElidesNothing() async throws {
        let drainSubject = try ExchangeHarness.otherSubject
        let staging = try await HealthUploadStaging.resolvedForTesting()
        let sample = ExchangeHarness.steps(0)
        try await staging.add([sample])
        staging.testing?.subject = drainSubject

        try Self.delete([sample], in: staging)

        #expect(try staging.fetchCount(of: HealthUploadStaging.PendingSampleRecord.self) == 1)
        #expect(try staging.fetchCount(of: HealthUploadStaging.PendingDeletionRecord.self) == 1)
        let early = try await DrainRecording().deletions(of: staging, subject: drainSubject)
        #expect(early.staged.isEmpty, "A deletion waits for the sample it matches, whosever it is")
        #expect(try staging.fetchCount(of: HealthUploadStaging.PendingDeletionRecord.self) == 1)
        let samples = try await DrainRecording().samples(of: staging, subject: drainSubject)
        #expect(samples.staged.isEmpty)
        #expect(samples.unreadable.isEmpty)
        #expect(samples.events == [Self.event(.otherSubject, rows: 1)])
        let deletions = try await DrainRecording().deletions(of: staging, subject: drainSubject)
        #expect(try deletions.stagedVersions(kind: .retraction).map(\.count) == [1])
        #expect(deletions.events.isEmpty)
        #expect(try staging.isEmpty)
    }

    /// A row staged before v5 counts as the same subject's.
    @Test(arguments: [true, false])
    func ownDeletionElidesThePendingRow(storedSubject: Bool) async throws {
        let staging = try await HealthUploadStaging.resolvedForTesting()
        let sample = ExchangeHarness.steps(0)
        try await staging.add([sample])
        if !storedSubject {
            try staging.setStoredSubject(of: try #require(try staging.sampleRows().first), to: nil)
        }

        try Self.delete([sample], in: staging)

        #expect(try staging.isEmpty)
    }

    @Test
    func launchTimeElisionLeavesAnotherSubjectsRows() async throws {
        let staging = try await HealthUploadStaging.resolvedForTesting(autoElideUploadsWhenInsertingDeletions: false)
        let sample = ExchangeHarness.steps(0)
        try await staging.add([sample])
        staging.testing?.subject = try ExchangeHarness.otherSubject
        try Self.delete([sample], in: staging)

        #expect(try staging.elidePendingUploadsWherePossible(dryRun: true).isEmpty)
        #expect(try staging.elidePendingUploadsWherePossible().isEmpty)
        #expect(try staging.fetchCount(of: HealthUploadStaging.PendingSampleRecord.self) == 1)
        #expect(try staging.fetchCount(of: HealthUploadStaging.PendingDeletionRecord.self) == 1)

        // A row staged before v5 counts as the same subject's.
        try staging.setStoredSubject(of: try #require(try staging.sampleRows().first), to: nil)
        #expect(try staging.elidePendingUploadsWherePossible(dryRun: true) == [Self.stepCount: 1])
        #expect(try staging.elidePendingUploadsWherePossible() == [Self.stepCount: 1])
        #expect(try staging.isEmpty)
    }

    @Test
    func launchTimeElisionStillElidesTheSameSubjectsRows() async throws {
        let staging = try await HealthUploadStaging.resolvedForTesting(autoElideUploadsWhenInsertingDeletions: false)
        let sample = ExchangeHarness.steps(0)
        try await staging.add([sample])
        try Self.delete([sample], in: staging)

        #expect(try staging.elidePendingUploadsWherePossible(dryRun: true) == [Self.stepCount: 1])
        #expect(try staging.elidePendingUploadsWherePossible() == [Self.stepCount: 1])
        #expect(try staging.isEmpty)
    }
}


// MARK: v4 Rows

extension HealthUploadStagingDrainLivenessTests {
    /// A database as v4 left it, holding a row of each of `samples` and one deletion.
    private static func writeV4Database(at url: URL, samples: [Data]) async throws {
        let database = try DatabaseQueue(path: url.path(percentEncoded: false))
        try HealthUploadStaging.applyMigrations(to: database, upTo: "v4")
        try await database.write { db in
            for sample in samples {
                try db.execute(
                    sql: "INSERT INTO pendingSamples (id, timestamp, sampleType, sampleId, fhirJson) VALUES (?, ?, ?, ?, ?)",
                    arguments: [UUID(), ExchangeHarness.start, stepCount, UUID(), sample]
                )
            }
            try db.execute(
                sql: "INSERT INTO pendingDeletions (id, timestamp, sampleType, sampleId) VALUES (?, ?, ?, ?)",
                arguments: [UUID(), ExchangeHarness.start, stepCount, UUID()]
            )
        }
        try database.close()
    }

    /// The v5 migration records no subject, classifies each row by its payload (H20), and the drain attributes every such
    /// row to its own subject, whichever that is.
    @Test
    func v4RowsKeepNullSubjectsAndDrainAsTheDrainSubjects() async throws {
        try await withTemporaryRoot { root in
            let database = root.appending(path: "staging.sqlite3", directoryHint: .notDirectory)
            let resource = Self.legacyPayload(resourceType: "Observation")
            let eventBundle = Self.legacyPayload(resourceType: "Bundle")
            let corrupt = Self.corruptPayload()
            let payloads = [try resource.compressed(using: Zstd.self), try eventBundle.compressed(using: Zstd.self), corrupt]
            try await Self.writeV4Database(at: database, samples: payloads)

            let staging = try await HealthUploadStaging.resolvedForTesting(persistence: .onDisk(url: database))

            let rows = try staging.sampleRows()
            let deletions = try staging.deletionRows()
            #expect(rows.map(\.subjectSystem) == [nil, nil, nil])
            #expect(rows.map(\.subjectValue) == [nil, nil, nil])
            #expect(deletions.map(\.subjectSystem) == [nil])
            #expect(deletions.map(\.subjectValue) == [nil])
            #expect(rows.filter { $0.payloadFormat == .legacyEventBundle }.map(\.fhirJson) == [payloads[1]])
            #expect(rows.filter { $0.payloadFormat == .legacyResource }.count == 2)

            let drainSubject = try ExchangeHarness.otherSubject
            let sampleDrain = try await DrainRecording().samples(of: staging, subject: drainSubject)
            let deletionDrain = try await DrainRecording().deletions(of: staging, subject: drainSubject)

            let arrays = [splicedJSONArray([resource]), splicedJSONArray([eventBundle])]
            #expect(Set(try sampleDrain.stagedJSON) == Set(arrays))
            #expect(Set(sampleDrain.staged.map(\.name)) == Set(arrays.map { "\(Self.stepCount)_\(Self.digest($0)).json.zstd" }))
            #expect(sampleDrain.unreadable.map(\.contents) == [corrupt])
            #expect(sampleDrain.events == [Self.event(.unreadable, rows: 1)])
            #expect(try deletionDrain.stagedVersions(kind: .retraction).map(\.count) == [1])
            #expect(deletionDrain.events.isEmpty)
            #expect(try staging.isEmpty)
        }
    }
}


// MARK: Re-Drains

extension HealthUploadStagingDrainLivenessTests {
    /// Splits and names follow from the sorted rows and their stored bytes, so a crash before the chunk's removal repeats
    /// every name; a chunk the crash left claimed reports nothing, and its re-drain reports once.
    @Test(arguments: [false, true])
    func aSecondSampleDrainAfterACrashStagesTheSameFiles(forcingTheFallback: Bool) async throws {
        let staging = try await HealthUploadStaging.resolvedForTesting()
        try await staging.add((0..<4).map(ExchangeHarness.steps))
        let rows = try staging.sampleRows()
        let doomed = try Self.record(of: rows[3]).version.fullURL
        try staging.replacePayload(of: rows[0], with: Self.corruptPayload())
        try staging.replacePayload(of: rows[1], with: try Self.invalidPayload())
        for (format, resourceType) in [(PayloadFormat.legacyResource, "Observation"), (.legacyEventBundle, "Bundle")] {
            let payload = try Self.legacyPayload(resourceType: resourceType).compressed(using: Zstd.self)
            try staging.insertRow(Self.legacyRow(format, storing: payload))
        }
        let makeBundle = forcingTheFallback ? HealthUploadBatch.failingBundles(alone: [doomed]) : HealthUploadBatch.packBundle
        try staging.failRemoval(from: HealthUploadStaging.PendingSampleRecord.databaseTableName)

        let crashed = DrainRecording()
        await #expect(throws: (any Error).self) {
            try await crashed.samples(of: staging, makeBundle: makeBundle)
        }

        #expect(crashed.events.isEmpty)
        #expect(try staging.fetchCount(of: HealthUploadStaging.PendingSampleRecord.self) == 6)
        try staging.allowRemoval()
        let retried = try await DrainRecording().samples(of: staging, makeBundle: makeBundle)

        func bundleVersions(of drain: DrainRecording) throws -> [[RecordVersion]] {
            try drain.stagedJSON.dropLast(2).map { try packedRecords(in: $0).map(\.version) }
        }
        #expect(retried.staged.map(\.name) == crashed.staged.map(\.name))
        #expect(retried.staged.suffix(2) == crashed.staged.suffix(2))
        #expect(try bundleVersions(of: retried) == bundleVersions(of: crashed))
        #expect(retried.unreadable == crashed.unreadable)
        #expect(retried.events == (
            forcingTheFallback
                ? [Self.event(.unreadable, rows: 3), Self.event(.bundleValidation, rows: 2)]
                : [Self.event(.unreadable, rows: 2)]
        ))
        #expect(try staging.isEmpty)
    }

    /// The retractions are converted again, at another instant, but their keys, and so every name, repeat.
    @Test
    func aSecondDeletionDrainAfterACrashStagesTheSameFiles() async throws {
        let staging = try await HealthUploadStaging.resolvedForTesting()
        try Self.delete((0..<4).map(ExchangeHarness.steps), in: staging)
        let subject = try ExchangeHarness.subject
        let rows = try staging.deletionRows()
        let planned = try await staging.retractionBatch(for: rows, subject: subject).map { try #require(Self.record(of: $0)) }
        let makeBundle = HealthUploadBatch.failingBundles(alone: [planned[1].version.fullURL])
        let refusal = Self.refusing(rows[0].sampleId)
        try staging.failRemoval(from: HealthUploadStaging.PendingDeletionRecord.databaseTableName)

        let crashed = DrainRecording()
        await #expect(throws: (any Error).self) {
            try await crashed.deletions(of: staging, makeBundle: makeBundle, retractionOutcomes: refusal)
        }

        #expect(crashed.events.isEmpty)
        #expect(try staging.fetchCount(of: HealthUploadStaging.PendingDeletionRecord.self) == 4)
        try staging.allowRemoval()
        let retried = try await DrainRecording().deletions(of: staging, makeBundle: makeBundle, retractionOutcomes: refusal)

        #expect(retried.staged.map(\.name) == crashed.staged.map(\.name))
        #expect(try retried.stagedVersions(kind: .retraction) == [[planned[2].version], [planned[3].version]])
        #expect(retried.unreadable.map(\.name) == crashed.unreadable.map(\.name))
        #expect(Set(retried.unreadable.map { $0.name.hasSuffix(".deletion.zstd") }) == [true, false])
        #expect(retried.events == [
            Self.event(.unreadable, rows: 1),
            Self.event(.bundleValidation, rows: 3),
            Self.event(.retractionRefused, rows: 1)
        ])
        #expect(try staging.isEmpty)
    }
}


extension HealthUploadStaging {
    /// The staged sample rows, in the order a drain sorts them.
    fileprivate func sampleRows() throws -> [PendingSampleRecord] {
        try writeForTesting { db in
            try PendingSampleRecord.fetchAll(db)
        }.sorted {
            $0.sampleId.uuidString.lowercased() < $1.sampleId.uuidString.lowercased()
        }
    }

    /// The staged deletion rows, in the order a drain sorts them.
    fileprivate func deletionRows() throws -> [PendingDeletionRecord] {
        try writeForTesting { db in
            try PendingDeletionRecord.fetchAll(db)
        }.sorted {
            $0.sampleId.uuidString.lowercased() < $1.sampleId.uuidString.lowercased()
        }
    }

    /// Stages a row no insert path writes.
    fileprivate func insertRow(_ row: some PersistableRecord) throws {
        try writeForTesting { db in
            try row.insert(db)
        }
    }

    fileprivate func replacePayload(of row: PendingSampleRecord, with payload: Data) throws {
        try writeForTesting { db in
            _ = try PendingSampleRecord
                .filter(keys: [row.id])
                .updateAll(db, PendingSampleRecord.Columns.fhirJson.set(to: payload))
        }
    }

    /// Stores `row` under `subject`, or, as a row staged before v5, under none.
    fileprivate func setStoredSubject(of row: PendingSampleRecord, to subject: FHIRExchangeSubject?) throws {
        try writeForTesting { db in
            _ = try PendingSampleRecord
                .filter(keys: [row.id])
                .updateAll(
                    db,
                    PendingSampleRecord.Columns.subjectSystem.set(to: subject?.identity.system.rawValue),
                    PendingSampleRecord.Columns.subjectValue.set(to: subject?.identity.value)
                )
        }
    }

    /// Makes removing a chunk from `table` fail once its files are staged, as a crash before the removal leaves them.
    fileprivate func failRemoval(from table: String) throws {
        try writeForTesting { db in
            try db.execute(sql: """
                CREATE TRIGGER failRemoval BEFORE DELETE ON \(table)
                BEGIN SELECT RAISE(ABORT, 'removal fails'); END
                """)
        }
    }

    fileprivate func allowRemoval() throws {
        try writeForTesting { db in
            try db.execute(sql: "DROP TRIGGER failRemoval")
        }
    }
}
