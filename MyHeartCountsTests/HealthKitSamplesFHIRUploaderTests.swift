//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFoundation
import GroveHealthKit
import GroveHealthKitFHIR
import HealthKit
@testable import MyHeartCounts
import Testing


/// The bulk export stages each batch through one exporter call and holds the batch's events until the bulk session
/// has durably recorded the batch as processed.
@Suite
struct HealthKitSamplesFHIRUploaderTests {
    private struct StagingFailure: Error {}

    private let ledger = FHIRExchangeLedger.forTesting()
    private let harness: LedgerHarness

    init() {
        harness = LedgerHarness(ledger: ledger)
    }

    /// The bulk session's processor, exporting through the ledger harness and staging into `files`, or failing to stage.
    private func bulkUploader(files: StagedUploadFiles = StagedUploadFiles(), failsToStage: Bool = false) -> HealthKitSamplesFHIRUploader {
        let harness = harness
        return HealthKitSamplesFHIRUploader {
            HealthKit()
        } exporter: { _ in
            try harness.exporter()
        } stage: { file, _ in
            if failsToStage {
                throw StagingFailure()
            }
            try files.stage(file)
        }
    }

    /// M4, M7: a batch of 1 000 samples reserves in one ledger transaction, and releases in one more only once the
    /// session persisted it.
    @Test
    func thousandSamplesCostOneReserveAndOneReleaseAfterPersistence() async throws {
        let counter = try ledger.countingTransactions()
        let files = StagedUploadFiles()
        let uploader = bulkUploader(files: files)

        let receipt = try await uploader.process((0..<1000).map(LedgerHarness.steps), of: .stepCount)
        #expect(files.all.count == 1)
        #expect(counter.transactions == 1)
        #expect(try ledger.reservationCount == 1000)

        await uploader.didPersist(receipt)
        #expect(counter.transactions == 2)
        #expect(try ledger.reservationCount == 0)
    }

    /// M4: the staged file is the batch's graphs, each one's validated bytes spliced in verbatim, in sample order.
    @Test
    func stagedFileSplicesTheGraphsJSON() async throws {
        let samples = (0..<4).map(LedgerHarness.steps)
        let files = StagedUploadFiles()
        let uploader = bulkUploader(files: files)
        let receipt = try await uploader.process(samples, of: .stepCount)

        // Before the batch is persisted, the same exporter reproduces the events the batch reserved.
        let graphs = try harness.exporter().deliver(samples)
        let ordered = graphs.graphs.sorted { $0.key.uuidString.lowercased() < $1.key.uuidString.lowercased() }
        #expect(files.all == [splicedJSONArray(ordered.map(\.value))])
        graphs.receipt?.release()
        await uploader.didPersist(receipt)
    }

    /// M7: a batch whose file could not be staged releases nothing, so the redelivery stages the same bytes.
    @Test
    func batchThatFailsToStageKeepsItsEventsForTheRedelivery() async throws {
        let samples = (0..<3).map(LedgerHarness.steps)
        await #expect(throws: StagingFailure.self) {
            _ = try await bulkUploader(failsToStage: true).process(samples, of: .stepCount)
        }
        #expect(try ledger.reservationCount == 3)

        let files = StagedUploadFiles()
        let uploader = bulkUploader(files: files)
        let first = try await uploader.process(samples, of: .stepCount)
        let redelivery = try await uploader.process(samples, of: .stepCount)
        #expect(files.all.count == 2)
        #expect(files.all.first == files.all.last)
        #expect(try ledger.producerEntry().next == "4", "every delivery reused the first one's events")
        await uploader.didPersist(first)
        await uploader.didPersist(redelivery)
        #expect(try ledger.reservationCount == 0)
    }
}
