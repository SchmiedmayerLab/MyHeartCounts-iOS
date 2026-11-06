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
import HealthKit
@testable import MyHeartCounts
import Synchronization
import Testing


/// A batch of records fresh from an exporter, as the historical and the `.firebaseStorage` paths upload it.
@Suite
struct HealthUploadBatchStagingTests {
    private static let stepCount = HKQuantityTypeIdentifier.stepCount.rawValue

    /// The records of `count` samples, in sample order.
    private static func records(count: Int, subject: FHIRExchangeSubject? = nil) async throws -> [ExchangeRecord] {
        let samples = (0..<count).map(ExchangeHarness.steps)
        let delivery = try await ExchangeHarness().exporter(subject: subject).deliver(samples)
        return try samples.map { try #require(delivery.records[$0.uuid]) }
    }

    /// A batch has no size limit, so each pass's Bundles are staged, and released, before the next pass packs.
    @Test
    func aBatchStagesEachPassBeforeItPacksTheNext() async throws {
        let steps = Mutex<[String]>([])

        try await HealthUploadBatch.stage(
            try await Self.records(count: 5),
            sampleType: Self.stepCount,
            packedAt: ExchangeHarness.start,
            recordsPerPass: 2,
            makeBundle: { packer, packedAt throws(ExchangeGraphError) in
                steps.withLock { $0.append("pack \(packer.recordCount)") }
                return try packer.bundle(packedAt: packedAt)
            },
            stage: { _ in
                steps.withLock { $0.append("stage") }
            },
            stageUnreadable: { file in
                Issue.record("Unexpected unreadable object \(file.lastPathComponent)")
            }
        )

        #expect(steps.withLock { $0 } == ["pack 2", "stage", "pack 2", "stage", "pack 1", "stage"])
    }

    /// A record no one-record Bundle can carry leaves through `stageUnreadable`, and every other record still leaves in a
    /// Bundle: nothing throws, so the batch is acknowledged.
    @Test
    func aRecordThatFailsAloneLeavesAsAnUnreadableObject() async throws {
        let records = try await Self.records(count: 3)
        let doomed = records[1]
        let files = StagedUploadFiles()
        let unreadable = StagedUploadFiles()

        try await HealthUploadBatch.stage(
            records,
            sampleType: Self.stepCount,
            packedAt: ExchangeHarness.start,
            makeBundle: HealthUploadBatch.failingBundles(alone: [doomed.version.fullURL]),
            stage: { try files.stage($0) },
            stageUnreadable: { try unreadable.stage($0) }
        )

        #expect(try files.records.map(\.version) == [records[0].version, records[2].version])
        #expect(unreadable.all == [doomed.json])
        #expect(unreadable.names == [
            HealthUploadBatch.filename(
                typePrefix: "unreadable_\(Self.stepCount)",
                provenanceFullURLs: [doomed.version.fullURL],
                fileExtension: "zstd"
            )
        ])
    }

    /// One exporter can't state two subjects, and an upload must not mix them: such a pass stages nothing.
    @Test
    func aRecordOfAnotherSubjectFailsThePassBeforeItStages() async throws {
        let records = try await Self.records(count: 1) + Self.records(count: 1, subject: try ExchangeHarness.otherSubject)
        let files = StagedUploadFiles()

        await #expect(throws: HealthUploadBatch.PackingError.self) {
            try await HealthUploadBatch.stage(
                records,
                sampleType: Self.stepCount,
                packedAt: ExchangeHarness.start,
                stage: { try files.stage($0) },
                stageUnreadable: { try files.stage($0) }
            )
        }

        #expect(files.all.isEmpty)
    }

    /// Under one instant a live upload's redelivery is an exact retry: every byte and the name repeat. Another instant states
    /// new versions of the same source records.
    @Test
    func liveUploadFileRepeatsEveryByteOnlyUnderOneInstant() async throws {
        let staging = try await HealthUploadStaging.resolvedForTesting()
        let accountDataGeneration = LocalPreferencesStore.standard[.accountDataGeneration]
        let samples = (0..<3).map(ExchangeHarness.steps)
        func deliver(at instant: Date, to files: StagedUploadFiles) async throws {
            var dependencies = MyHeartCountsStandard.HealthObservationUploadDependencies.testing(staging: staging, files: files)
            dependencies.now = { instant }
            try await MyHeartCountsStandard.uploadHealthObservations(
                samples,
                accountDataGeneration: accountDataGeneration,
                uploadStrategy: .firebaseStorage,
                through: dependencies
            )
        }

        let first = StagedUploadFiles()
        let retry = StagedUploadFiles()
        let later = StagedUploadFiles()
        try await deliver(at: ExchangeHarness.start, to: first)
        try await deliver(at: ExchangeHarness.start, to: retry)
        try await deliver(at: ExchangeHarness.start.addingTimeInterval(60), to: later)

        #expect(retry.all == first.all)
        #expect(retry.names == first.names)
        #expect(later.names != first.names)
        #expect(try later.records.map(\.sourceRecord) == first.records.map(\.sourceRecord))
        #expect(Set(try later.records.map(\.version)).isDisjoint(with: try first.records.map(\.version)))
    }

    /// File names follow from content, so two writers of the same bytes must not share a file: the one finishing first would
    /// remove what the other is still staging.
    @Test
    func writersOfTheSameBytesEachHaveTheirOwnFile() async throws {
        let contents = Data("the same bytes".utf8)
        let name = "same-name.json.zstd"
        var outerFile: URL?

        try await HealthUploadBatch.stageFile(contents, filename: name) { outer in
            outerFile = outer
            try await HealthUploadBatch.stageFile(contents, filename: name) { inner in
                #expect(inner != outer)
                #expect(inner.lastPathComponent == name)
            }
            #expect(try Data(contentsOf: outer) == contents)
        }

        let file = try #require(outerFile)
        #expect(file.lastPathComponent == name)
        #expect(!FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path(percentEncoded: false)))
    }
}
