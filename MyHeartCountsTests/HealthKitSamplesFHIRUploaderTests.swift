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

    /// Exports `samples` as one bulk batch, returning its reservations and the decompressed file it staged.
    private func stage(_ samples: [HKSample]) async throws -> (receipt: HealthKitFHIRReservationReceipt, staged: Data?) {
        let harness = harness
        var staged: Data?
        let receipt = try await HealthKitSamplesFHIRUploader.stageBatch(
            samples,
            typePrefix: HKQuantityTypeIdentifier.stepCount.rawValue,
            using: HealthKit()
        ) {
            try harness.exporter()
        } stage: { url in
            staged = try Data(contentsOf: url).decompressed(using: Zstd.self)
        }
        return (receipt, staged)
    }

    /// M4, M7: a batch of 1 000 samples reserves in one ledger transaction, and releases in one more only once the
    /// session persisted it.
    @Test
    func thousandSamplesCostOneReserveAndOneReleaseAfterPersistence() async throws {
        let counter = try ledger.countingTransactions()

        let (receipt, staged) = try await stage((0..<1000).map(LedgerHarness.steps))
        #expect(staged != nil)
        #expect(counter.transactions == 1)
        #expect(try ledger.reservationCount == 1000)

        await HealthKitSamplesFHIRUploader(standard: MyHeartCountsStandard()).didPersist(receipt)
        #expect(counter.transactions == 2)
        #expect(try ledger.reservationCount == 0)
    }

    /// M4: the staged file is the batch's graphs, each one's validated bytes spliced in verbatim, in sample order.
    @Test
    func stagedFileSplicesTheGraphsJSON() async throws {
        let samples = (0..<4).map(LedgerHarness.steps)
        let (receipt, staged) = try await stage(samples)

        // Before the batch is persisted, the same exporter reproduces the events the batch reserved.
        let graphs = try harness.exporter().deliver(samples)
        let ordered = graphs.graphs.sorted { $0.key.uuidString.lowercased() < $1.key.uuidString.lowercased() }
        #expect(staged == splicedJSONArray(ordered.map(\.value)))
        graphs.receipt?.release()
        receipt.completeAfterSourceAcknowledgement()
    }

    /// M7: a batch whose file could not be staged releases nothing, so the redelivery stages the same bytes.
    @Test
    func batchThatFailsToStageKeepsItsEventsForTheRedelivery() async throws {
        let samples = (0..<3).map(LedgerHarness.steps)
        let harness = harness
        await #expect(throws: StagingFailure.self) {
            _ = try await HealthKitSamplesFHIRUploader.stageBatch(samples, typePrefix: "steps", using: HealthKit()) {
                try harness.exporter()
            } stage: { _ in
                throw StagingFailure()
            }
        }
        #expect(try ledger.reservationCount == 3)

        let (first, firstStaged) = try await stage(samples)
        let (redelivery, redeliveryStaged) = try await stage(samples)
        #expect(redeliveryStaged == firstStaged)
        #expect(try ledger.producerEntry().next == "4", "every delivery reused the first one's events")
        first.completeAfterSourceAcknowledgement()
        redelivery.completeAfterSourceAcknowledgement()
        #expect(try ledger.reservationCount == 0)
    }
}
