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
import GroveHealthKit
import GroveHealthKitFHIR
import HealthKit
@testable import MyHeartCounts
import Testing


/// The bulk export stages each batch through one exporter call, as one packed Bundle of the batch's records.
///
/// The uploader stamps each batch with the instant it is converted at, so two exports of a batch always repeat its source
/// records, and its record versions and bytes only under one instant.
@Suite
struct HealthKitSamplesFHIRUploaderTests {
    private struct StagingFailure: Error {}

    private let harness = ExchangeHarness()

    /// The bulk session's processor, exporting through the harness and staging into `files`, or failing to stage.
    private func bulkUploader(
        files: StagedUploadFiles = StagedUploadFiles(),
        unreadable: StagedUploadFiles = StagedUploadFiles(),
        failsToStage: Bool = false,
        now: @escaping @Sendable () -> Date = { .now },
        makeBundle: @escaping HealthUploadBatch.MakeBundle = HealthUploadBatch.packBundle
    ) -> HealthKitSamplesFHIRUploader {
        let harness = harness
        return HealthKitSamplesFHIRUploader(healthKit: HealthKit(), now: now, makeBundle: makeBundle) { _ in
            try harness.exporter()
        } stage: { file, _ in
            if failsToStage {
                throw StagingFailure()
            }
            try files.stage(file)
        } stageUnreadable: { file, _ in
            try unreadable.stage(file)
        }
    }

    /// M4: a batch of 1 000 samples is one file, whose one Bundle holds a record per sample.
    @Test
    func thousandSamplesStageOneBundle() async throws {
        let files = StagedUploadFiles()
        let uploader = bulkUploader(files: files)

        try await uploader.process((0..<1000).map(ExchangeHarness.steps), of: .stepCount)

        #expect(files.all.count == 1)
        #expect(try files.records.count == 1000)
    }

    /// M4: the staged file is one Bundle of the batch's records, in sample order, named by their Provenances.
    @Test
    func stagedFileIsOneBundleOfTheBatchsRecords() async throws {
        let samples = (0..<4).map(ExchangeHarness.steps)
        let files = StagedUploadFiles()
        try await bulkUploader(files: files).process(samples, of: .stepCount)

        #expect(files.all.count == 1)
        let records = try files.records
        let delivery = try await harness.exporter().deliver(samples)
        #expect(records.map(\.sourceRecord) == samples.compactMap { delivery.records[$0.uuid]?.sourceRecord })
        #expect(files.names == [
            HealthUploadBatch.filename(
                typePrefix: SampleType.stepCount.id,
                provenanceFullURLs: records.map(\.version.fullURL),
                fileExtension: "json.zstd"
            )
        ])
    }

    /// M7: a batch whose file could not be staged fails, so the session keeps it, and its redelivery states the same source
    /// records.
    @Test
    func batchThatFailsToStageIsRedeliveredAsTheSameSourceRecords() async throws {
        let samples = (0..<3).map(ExchangeHarness.steps)
        await #expect(throws: StagingFailure.self) {
            try await bulkUploader(failsToStage: true).process(samples, of: .stepCount)
        }

        let files = StagedUploadFiles()
        let uploader = bulkUploader(files: files)
        try await uploader.process(samples, of: .stepCount)
        try await uploader.process(samples, of: .stepCount)

        #expect(files.all.count == 2)
        let first = try packedRecords(in: try #require(files.all.first))
        let redelivery = try packedRecords(in: try #require(files.all.last))
        #expect(first.count == samples.count)
        #expect(redelivery.map(\.sourceRecord) == first.map(\.sourceRecord))
    }

    /// Under one instant a redelivery is an exact retry: every byte and the name repeat. Another instant states new versions.
    @Test
    func aRedeliveryRepeatsEveryByteOnlyUnderOneInstant() async throws {
        let samples = (0..<3).map(ExchangeHarness.steps)
        let files = StagedUploadFiles()
        let uploader = bulkUploader(files: files) { ExchangeHarness.start }
        try await uploader.process(samples, of: .stepCount)
        try await uploader.process(samples, of: .stepCount)
        let later = StagedUploadFiles()
        try await bulkUploader(files: later) { ExchangeHarness.start.addingTimeInterval(60) }.process(samples, of: .stepCount)

        #expect(files.all.count == 2)
        #expect(files.all.first == files.all.last)
        #expect(files.names.first == files.names.last)
        #expect(later.names != [try #require(files.names.first)])
        let records = try packedRecords(in: try #require(files.all.first))
        let laterRecords = try later.records
        #expect(laterRecords.map(\.sourceRecord) == records.map(\.sourceRecord))
        #expect(Set(laterRecords.map(\.version)).isDisjoint(with: records.map(\.version)))
    }

    /// A record no Bundle can carry costs only itself: it leaves as an `unreadable_` object, named by its keyed Provenance,
    /// and the batch completes, so the session does not retry it forever.
    @Test
    func aRecordThatFailsAloneLeavesAsAnUnreadableObjectAndTheBatchCompletes() async throws {
        let samples = (0..<3).map(ExchangeHarness.steps)
        let delivery = try await harness.exporter().deliver(samples)
        let records = try samples.map { try #require(delivery.records[$0.uuid]) }
        let doomed = records[1]
        let files = StagedUploadFiles()
        let unreadable = StagedUploadFiles()
        let uploader = bulkUploader(
            files: files,
            unreadable: unreadable,
            now: { ExchangeHarness.start },
            makeBundle: HealthUploadBatch.failingBundles(alone: [doomed.version.fullURL])
        )

        try await uploader.process(samples, of: .stepCount)

        #expect(try files.records.map(\.version) == [records[0].version, records[2].version])
        #expect(unreadable.all == [doomed.json])
        #expect(unreadable.names == [
            HealthUploadBatch.filename(
                typePrefix: "unreadable_\(SampleType.stepCount.id)",
                provenanceFullURLs: [doomed.version.fullURL],
                fileExtension: "zstd"
            )
        ])
    }
}
