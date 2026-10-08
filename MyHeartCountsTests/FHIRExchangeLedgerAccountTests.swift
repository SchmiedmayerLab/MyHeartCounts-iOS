//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GRDB
import GroveFHIRContract
import GroveFoundation
import GroveHealthKitFHIR
import HealthKit
@testable import MyHeartCounts
import OSLog
import Testing


/// M2 and M8: every ledger transaction is fenced to the live account generation, and the account cleanup
/// empties the ledger.
@Suite
struct FHIRExchangeLedgerAccountTests {
    private struct StepFailure: Error {}

    private let preferences = TestAccountPreferences(generation: 0)

    /// A ledger fenced by this test's preferences.
    private func makeLedger() -> FHIRExchangeLedger {
        FHIRExchangeLedger(location: .inMemory, fence: preferences.fence)
    }

    /// The account-data cleanup `clearPendingAccountData` runs, over this test's preferences and `ledger`.
    private func clearAccountData(
        _ ledger: FHIRExchangeLedger,
        steps: [MyHeartCountsStandard.AccountDataCleanupStep] = []
    ) async throws {
        try await MyHeartCountsStandard.clearAccountData(
            steps,
            exchangeLedger: ledger,
            preferences: preferences.store,
            logger: Logger(subsystem: "edu.stanford.MyHeartCounts.unitTests", category: "FHIRExchangeLedgerAccountTests")
        )
    }

    /// A logout: `performLogoutCleanup` sets the flag and rotates the generation, then clears the account data.
    private func logOut(_ ledger: FHIRExchangeLedger, rotatingTo generation: Int) async throws {
        preferences.set(generation: generation, cleanupPending: true)
        try await clearAccountData(ledger)
    }

    @Test
    func staleWriterIsRefusedBeforeItWrites() async throws {
        let harness = LedgerHarness(ledger: makeLedger())
        preferences.set(generation: 1, cleanupPending: false)

        await #expect(throws: FHIRExchangeDestinationError.accountChanged) {
            try await harness.deliver([LedgerHarness.steps(0)], generation: 0)
        }
        #expect(try harness.ledger.entriesForTesting().isEmpty)
        #expect(try harness.ledger.storedAccountGeneration() == nil)
    }

    @Test
    func pendingCleanupRefusesEveryWriter() async throws {
        let harness = LedgerHarness(ledger: makeLedger())
        let receipt = try await #require(try harness.deliver([LedgerHarness.steps(0)]).receipt)
        let entries = try harness.ledger.entriesForTesting()
        preferences.set(cleanupPending: true)

        await #expect(throws: FHIRExchangeDestinationError.accountChanged) {
            try await harness.deliver([LedgerHarness.steps(1)])
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
    func ledgerOfAnEarlierGenerationIsEmptiedByTheLiveWriter() async throws {
        let harness = LedgerHarness(ledger: makeLedger())
        let sample = LedgerHarness.steps(0)
        let old = try await #require(try harness.deliver([sample]).events[sample.uuid])
        #expect(try harness.ledger.storedAccountGeneration() == 0)

        preferences.set(generation: 1, cleanupPending: false)
        let new = try await #require(try harness.deliver([sample], generation: 1).events[sample.uuid])

        #expect(new.producerInstance != old.producerInstance)
        #expect(new.sequence.rawValue == "1")
        #expect(try harness.ledger.entryKeys(prefixedBy: "event/").count == 1)
        #expect(try harness.ledger.storedAccountGeneration() == 1)
    }

    /// A stored generation ahead of the live one, such as after the preferences were lost, heals the same way.
    @Test
    func ledgerOfALaterGenerationIsEmptiedByTheLiveWriter() async throws {
        let harness = LedgerHarness(ledger: makeLedger())
        let sample = LedgerHarness.steps(0)
        preferences.set(generation: 2, cleanupPending: false)
        let ahead = try await #require(try harness.deliver([sample], generation: 2).events[sample.uuid])

        preferences.set(generation: 1, cleanupPending: false)
        let live = try await #require(try harness.deliver([sample], generation: 1).events[sample.uuid])

        #expect(live.producerInstance != ahead.producerInstance)
        #expect(try harness.ledger.storedAccountGeneration() == 1)
    }

    /// M2: while the ledger cannot be reset, the account-data cleanup fails although every other step succeeded,
    /// cleanup stays pending, and the fence keeps refusing every export until a later cleanup succeeds.
    @Test
    func failingLedgerResetKeepsTheCleanupPending() async throws {
        let harness = LedgerHarness(ledger: makeLedger())
        let sample = LedgerHarness.steps(0)
        let old = try await #require(try harness.deliver([sample]).events[sample.uuid])
        try harness.ledger.withDatabaseForTesting { db in
            try db.execute(sql: "CREATE TEMP TRIGGER failReset BEFORE DELETE ON ledgerEntry BEGIN SELECT RAISE(ABORT, 'injected'); END")
        }
        var otherStepRan = false

        preferences.set(generation: 1, cleanupPending: true)
        await #expect(throws: (any Error).self) {
            try await clearAccountData(harness.ledger, steps: [.init("other data") { otherStepRan = true }])
        }
        #expect(otherStepRan)
        #expect(preferences.store[.pendingAccountDataCleanupRequired])
        await #expect(throws: FHIRExchangeDestinationError.accountChanged) {
            try await harness.deliver([sample], generation: 1)
        }

        try harness.ledger.withDatabaseForTesting { db in
            try db.execute(sql: "DROP TRIGGER failReset")
        }
        try await clearAccountData(harness.ledger)
        #expect(!preferences.store[.pendingAccountDataCleanupRequired])
        #expect(try harness.ledger.entriesForTesting().isEmpty)
        let next = try await #require(try harness.deliver([sample], generation: 1).events[sample.uuid])
        #expect(next.producerInstance != old.producerInstance)
        #expect(next.sequence.rawValue == "1")
    }

    /// Any other failing step keeps cleanup pending too, and the ledger is reset all the same.
    @Test
    func failingStepKeepsTheCleanupPendingAndStillResetsTheLedger() async throws {
        let ledger = makeLedger()
        _ = try await LedgerHarness(ledger: ledger).deliver([LedgerHarness.steps(0)])

        preferences.set(generation: 1, cleanupPending: true)
        await #expect(throws: (any Error).self) {
            try await clearAccountData(ledger, steps: [.init("other data") { throw StepFailure() }])
        }
        #expect(preferences.store[.pendingAccountDataCleanupRequired])
        #expect(try ledger.entriesForTesting().isEmpty)
        #expect(try ledger.storedAccountGeneration() == 1)
    }

    /// A receipt of the previous account released after the cleanup changes nothing, not even the active
    /// reservation a retraction receipt forgets unconditionally.
    @Test
    func lateReleaseFromAnOldGenerationChangesNothing() async throws {
        let harness = LedgerHarness(ledger: makeLedger())
        let sample = LedgerHarness.steps(0)
        let deletion = HealthKitFHIRExporter.Deletion(
            uuid: sample.uuid,
            sourceType: try #require(HealthKitSourceType(rawValue: sample.sampleType.identifier)),
            deletedAfter: nil,
            detectedAt: LedgerHarness.start
        )
        let oldRetraction = try await harness.exporter(generation: 0).retract([deletion], at: LedgerHarness.start) { _ in }

        try await logOut(harness.ledger, rotatingTo: 1)
        let reserved = try await harness.deliver([sample], generation: 1)
        let entries = try harness.ledger.entriesForTesting()
        oldRetraction.release()

        #expect(try harness.ledger.entriesForTesting() == entries)
        #expect(reserved.events.count == 1)
    }

    /// M8: the account-data cleanup `clearPendingAccountData` runs empties the ledger at the generation the
    /// logout rotated to, ends the pending cleanup and rotates the producer instance; the previous account's
    /// exporters are refused and its receipts change nothing.
    @Test
    func accountCleanupRotatesTheInstance() async throws {
        let harness = LedgerHarness(ledger: makeLedger())
        let samples = [LedgerHarness.steps(0), LedgerHarness.steps(1)]
        let oldExporter = try harness.exporter(generation: 0)
        let old = try await oldExporter.deliver(samples)

        try await logOut(harness.ledger, rotatingTo: 1)
        #expect(!preferences.store[.pendingAccountDataCleanupRequired])
        #expect(try harness.ledger.entriesForTesting().isEmpty)
        #expect(try harness.ledger.storedAccountGeneration() == 1)

        let new = try await harness.deliver([samples[0]], generation: 1)
        let event = try #require(new.events[samples[0].uuid])
        #expect(event.producerInstance != old.events[samples[0].uuid]?.producerInstance)
        #expect(event.sequence.rawValue == "1")

        await #expect(throws: FHIRExchangeDestinationError.accountChanged) {
            try await oldExporter.deliver([LedgerHarness.steps(2)])
        }
        let entries = try harness.ledger.entriesForTesting()
        old.receipt?.release()
        #expect(try harness.ledger.entriesForTesting() == entries)
    }
}
