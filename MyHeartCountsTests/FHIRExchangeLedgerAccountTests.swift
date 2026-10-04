//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFHIRContract
import GroveHealthKitFHIR
import HealthKit
@testable import MyHeartCounts
import Testing


/// M2 and M8: every ledger transaction is fenced to the live account generation, and the account cleanup
/// empties the ledger.
@Suite
struct FHIRExchangeLedgerAccountTests {
    private let preferences = TestAccountPreferences(generation: 0)

    /// A ledger fenced by this test's preferences.
    private func makeLedger() -> FHIRExchangeLedger {
        FHIRExchangeLedger(location: .inMemory, fence: preferences.fence)
    }

    /// The order `performLogoutCleanup` and `clearPendingAccountData` follow: flag, rotate, reset, unflag.
    private func cleanUpAccount(_ ledger: FHIRExchangeLedger, rotatingTo generation: Int) throws {
        preferences.set(generation: generation, cleanupPending: true)
        try ledger.reset(toAccountDataGeneration: generation)
        preferences.set(cleanupPending: false)
    }

    @Test
    func staleWriterIsRefusedBeforeItWrites() throws {
        let harness = LedgerHarness(ledger: makeLedger())
        preferences.set(generation: 1, cleanupPending: false)

        #expect(throws: FHIRExchangeDestinationError.accountChanged) {
            try harness.deliver([LedgerHarness.steps(0)], generation: 0)
        }
        #expect(try harness.ledger.entriesForTesting().isEmpty)
        #expect(try harness.ledger.storedAccountGeneration() == nil)
    }

    @Test
    func pendingCleanupRefusesEveryWriter() throws {
        let harness = LedgerHarness(ledger: makeLedger())
        let receipt = try #require(try harness.deliver([LedgerHarness.steps(0)]).receipt)
        let entries = try harness.ledger.entriesForTesting()
        preferences.set(cleanupPending: true)

        #expect(throws: FHIRExchangeDestinationError.accountChanged) {
            try harness.deliver([LedgerHarness.steps(1)])
        }
        #expect(throws: FHIRExchangeDestinationError.accountChanged) {
            try harness.ledger.recover(accountDataGeneration: 0)
        }
        receipt.release()
        #expect(try harness.ledger.entriesForTesting() == entries)
    }

    /// The live generation moved on without the ledger being reset: the next writer of the live generation
    /// empties it and adopts its generation.
    @Test
    func ledgerOfAnEarlierGenerationIsEmptiedByTheLiveWriter() throws {
        let harness = LedgerHarness(ledger: makeLedger())
        let sample = LedgerHarness.steps(0)
        let old = try #require(try harness.deliver([sample]).events[sample.uuid])
        #expect(try harness.ledger.storedAccountGeneration() == 0)

        preferences.set(generation: 1, cleanupPending: false)
        let new = try #require(try harness.deliver([sample], generation: 1).events[sample.uuid])

        #expect(new.producerInstance != old.producerInstance)
        #expect(new.sequence.rawValue == "1")
        #expect(try harness.ledger.entryKeys(prefixedBy: "event/").count == 1)
        #expect(try harness.ledger.storedAccountGeneration() == 1)
    }

    /// A stored generation ahead of the live one, such as after the preferences were lost, heals the same way.
    @Test
    func ledgerOfALaterGenerationIsEmptiedByTheLiveWriter() throws {
        let harness = LedgerHarness(ledger: makeLedger())
        let sample = LedgerHarness.steps(0)
        preferences.set(generation: 2, cleanupPending: false)
        let ahead = try #require(try harness.deliver([sample], generation: 2).events[sample.uuid])

        preferences.set(generation: 1, cleanupPending: false)
        let live = try #require(try harness.deliver([sample], generation: 1).events[sample.uuid])

        #expect(live.producerInstance != ahead.producerInstance)
        #expect(try harness.ledger.storedAccountGeneration() == 1)
    }

    /// While the ledger cannot be reset, cleanup stays pending, and the fence keeps refusing every export.
    @Test
    func failingResetLeavesTheLedgerFenced() throws {
        try withTemporaryDirectory { root in
            let harness = LedgerHarness(ledger: .inDirectory(root, preferences: preferences))
            preferences.set(generation: 1, cleanupPending: true)
            let rootPath = root.path(percentEncoded: false)
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: rootPath)
            #expect(throws: (any Error).self) {
                try harness.ledger.reset(toAccountDataGeneration: 1)
            }

            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: rootPath)
            #expect(throws: FHIRExchangeDestinationError.accountChanged) {
                try harness.deliver([LedgerHarness.steps(0)], generation: 1)
            }

            try cleanUpAccount(harness.ledger, rotatingTo: 1)
            #expect(try harness.deliver([LedgerHarness.steps(0)], generation: 1).events.count == 1)
        }
    }

    /// A receipt of the previous account released after the cleanup changes nothing, not even the active
    /// reservation a retraction receipt forgets unconditionally.
    @Test
    func lateReleaseFromAnOldGenerationChangesNothing() throws {
        let harness = LedgerHarness(ledger: makeLedger())
        let sample = LedgerHarness.steps(0)
        let deletion = HealthKitFHIRExporter.Deletion(
            uuid: sample.uuid,
            sourceType: try #require(HealthKitSourceType(rawValue: sample.sampleType.identifier)),
            deletedAfter: nil,
            detectedAt: LedgerHarness.start
        )
        let oldRetraction = try harness.exporter(generation: 0).retract([deletion], at: LedgerHarness.start) { _ in }

        try cleanUpAccount(harness.ledger, rotatingTo: 1)
        let reserved = try harness.deliver([sample], generation: 1)
        let entries = try harness.ledger.entriesForTesting()
        oldRetraction.release()

        #expect(try harness.ledger.entriesForTesting() == entries)
        #expect(reserved.events.count == 1)
    }

    /// M8: the account cleanup empties the ledger and rotates the producer instance; the previous account's
    /// exporters are refused and its receipts change nothing.
    @Test
    func accountCleanupRotatesTheInstance() throws {
        let harness = LedgerHarness(ledger: makeLedger())
        let samples = [LedgerHarness.steps(0), LedgerHarness.steps(1)]
        let oldExporter = try harness.exporter(generation: 0)
        let old = try oldExporter.deliver(samples)

        try cleanUpAccount(harness.ledger, rotatingTo: 1)
        #expect(try harness.ledger.entriesForTesting().isEmpty)
        #expect(try harness.ledger.storedAccountGeneration() == 1)

        let new = try harness.deliver([samples[0]], generation: 1)
        let event = try #require(new.events[samples[0].uuid])
        #expect(event.producerInstance != old.events[samples[0].uuid]?.producerInstance)
        #expect(event.sequence.rawValue == "1")

        #expect(throws: FHIRExchangeDestinationError.accountChanged) {
            try oldExporter.deliver([LedgerHarness.steps(2)])
        }
        let entries = try harness.ledger.entriesForTesting()
        old.receipt?.release()
        #expect(try harness.ledger.entriesForTesting() == entries)
    }
}
