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
import GroveHealthKitFHIR
import HealthKit
@testable import MyHeartCounts
import Synchronization
import Testing


/// Grove's storage contract, met by the GRDB ledger: exercised through the sequencer the exporter uses.
@Suite
struct FHIRExchangeLedgerContractTests {
    /// Which graph every handed-out event was first delivered with, across threads.
    private final class EventOracle: Sendable {
        private let delivered = Mutex<[String: Data]>([:])
        private let mismatches = Mutex(0)

        var mismatchCount: Int {
            mismatches.withLock { $0 }
        }

        var eventCount: Int {
            delivered.withLock { $0.count }
        }

        func record(_ delivery: LedgerDelivery) {
            for (source, event) in delivery.events {
                guard let graph = delivery.graphs[source] else {
                    continue
                }
                let key = "\(event.producerInstance.uuidString):\(event.sequence.rawValue)"
                let isMismatch = delivered.withLock { delivered in
                    if let earlier = delivered[key] {
                        return earlier != graph
                    }
                    delivered[key] = graph
                    return false
                }
                if isMismatch {
                    mismatches.withLock { $0 += 1 }
                }
            }
        }
    }

    private struct InjectedCommitFailure: Error {}

    /// Refuses the next commit, as a full disk or an I/O error at commit would.
    private final class FailingCommit: TransactionObserver {
        func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool {
            false
        }

        func databaseDidChange(with event: DatabaseEvent) {}

        func databaseWillCommit() throws {
            throw InjectedCommitFailure()
        }

        func databaseDidCommit(_ db: Database) {}

        func databaseDidRollback(_ db: Database) {}
    }

    /// G1: new keys take consecutive sequences from one, all under the instance the ledger's producer entry names.
    @Test
    func newKeysTakeConsecutiveSequencesUnderTheLedgersInstance() throws {
        try withTemporaryDirectory { root in
            let harness = LedgerHarness(ledger: .inDirectory(root))
            let delivery = try harness.deliver((0..<3).map(LedgerHarness.steps))
            let producer = try harness.ledger.producerEntry()

            #expect(Set(delivery.events.values.map(\.sequence.rawValue)) == ["1", "2", "3"])
            #expect(delivery.events.values.allSatisfy { $0.producerInstance == producer.instance })
            #expect(producer.next == "4")
            #expect(try harness.ledger.entryKeys(prefixedBy: "event/").count == 3)
            #expect(try harness.ledger.entryKeys(prefixedBy: "facts/").count == 1)
        }
    }

    /// Durability across a closed connection: the reservation is read back, and the redelivery is exact.
    @Test
    func reservationsSurviveClosingAndReopening() throws {
        try withTemporaryDirectory { root in
            let binding = InMemoryDeviceBinding()
            let harness = LedgerHarness(ledger: .inDirectory(root, binding: binding))
            let sample = LedgerHarness.steps(0)
            let first = try harness.deliver([sample])
            let entries = try harness.ledger.entriesForTesting()
            try harness.ledger.closeForTesting()

            let reopened = LedgerHarness(identity: harness.identity, ledger: .inDirectory(root, binding: binding))
            #expect(try reopened.ledger.entriesForTesting() == entries)
            let retry = try reopened.exporter().deliver([sample], at: LedgerHarness.start + 3600)
            #expect(retry.events == first.events)
            #expect(retry.graphs == first.graphs)
        }
    }

    /// G5: across random interleavings of exports, releases, lapses, resets, reopened connections and context
    /// changes, no event identifier is ever delivered with different bytes.
    @Test(arguments: [1, 2, 3] as [UInt64])
    func noEventIsEverDeliveredWithOtherContent(seed: UInt64) throws {
        try withTemporaryDirectory { root in
            let harness = LedgerHarness(ledger: .inDirectory(root))
            let otherSubject = try FHIRExchangeSubject(identity: BusinessIdentifier(
                system: FHIRExchangeIdentifiers.participant,
                value: "ledger-participant-2"
            ))
            let exporters = [try harness.exporter(), try harness.exporter(subject: otherSubject)]
            let samples = (0..<6).map(LedgerHarness.steps)
            let oracle = EventOracle()
            var receipts: [HealthKitFHIRExporter.Receipt] = []
            var random = SplitMix64(seed: seed)
            for step in 0..<150 {
                switch Int.random(in: 0..<10, using: &random) {
                case 0..<5:
                    let exporter = exporters[Int.random(in: 0..<exporters.count, using: &random)]
                    let chosen = samples.shuffled(using: &random).prefix(Int.random(in: 1...3, using: &random))
                    let delivery = try exporter.deliver(Array(chosen), at: LedgerHarness.start + TimeInterval(step))
                    oracle.record(delivery)
                    receipts.append(try #require(delivery.receipt))
                case 5..<7 where !receipts.isEmpty:
                    receipts.remove(at: Int.random(in: 0..<receipts.count, using: &random)).release()
                case 7 where !receipts.isEmpty:
                    // Dropped unreleased: the hold lapses.
                    receipts.remove(at: Int.random(in: 0..<receipts.count, using: &random))
                case 8:
                    try harness.ledger.sequencer(accountDataGeneration: 0).reset()
                default:
                    try harness.ledger.closeForTesting()
                }
            }

            #expect(oracle.mismatchCount == 0)
            #expect(oracle.eventCount > samples.count)
        }
    }

    /// G6: eight threads exporting and releasing while another resets never share an event identifier.
    @Test
    func concurrentExportsAndResetsNeverShareAnEvent() throws {
        try withTemporaryDirectory { root in
            let harness = LedgerHarness(ledger: .inDirectory(root))
            let exporter = try harness.exporter()
            let samples = (0..<12).map(LedgerHarness.steps)
            let oracle = EventOracle()
            let failures = Mutex(0)
            DispatchQueue.concurrentPerform(iterations: 9) { worker in
                do {
                    if worker == 8 {
                        for _ in 0..<10 {
                            try harness.ledger.sequencer(accountDataGeneration: 0).reset()
                            usleep(5_000)
                        }
                        return
                    }
                    var random = SplitMix64(seed: UInt64(worker))
                    for _ in 0..<25 {
                        let delivery = try exporter.deliver([samples[Int.random(in: 0..<samples.count, using: &random)]])
                        oracle.record(delivery)
                        if Bool.random(using: &random) {
                            delivery.receipt?.release()
                        }
                    }
                } catch {
                    failures.withLock { $0 += 1 }
                }
            }

            #expect(failures.withLock { $0 } == 0)
            #expect(oracle.mismatchCount == 0)
        }
    }

    /// G7: a write that fails inside the transaction leaves nothing behind, and the retry numbers from one.
    @Test
    func aFailedWriteLeavesNoPartialState() throws {
        let harness = LedgerHarness(ledger: .forTesting())
        let samples = (0..<3).map(LedgerHarness.steps)
        try harness.ledger.withDatabaseForTesting { db in
            try db.execute(sql: """
                CREATE TEMP TRIGGER failSecondEvent BEFORE INSERT ON ledgerEntry
                WHEN NEW.key LIKE 'event/%' AND (SELECT COUNT(*) FROM ledgerEntry WHERE key LIKE 'event/%') >= 1
                BEGIN SELECT RAISE(ABORT, 'injected'); END
                """)
        }

        #expect(throws: DatabaseError.self) {
            try harness.deliver(samples)
        }
        #expect(try harness.ledger.entriesForTesting().isEmpty)

        try harness.ledger.withDatabaseForTesting { db in
            try db.execute(sql: "DROP TRIGGER failSecondEvent")
        }
        let retry = try harness.deliver(samples)
        #expect(Set(retry.events.values.map(\.sequence.rawValue)) == ["1", "2", "3"])
        #expect(Set(retry.events.values.map(\.producerInstance)).count == 1)
    }

    /// G7: a commit that fails leaves nothing behind, and the retry numbers from one.
    @Test
    func aFailedCommitLeavesNoPartialState() throws {
        let harness = LedgerHarness(ledger: .forTesting())
        let samples = (0..<3).map(LedgerHarness.steps)
        try harness.ledger.withDatabaseForTesting { db in
            db.add(transactionObserver: FailingCommit(), extent: .nextTransaction)
        }

        #expect(throws: InjectedCommitFailure.self) {
            try harness.deliver(samples)
        }
        #expect(try harness.ledger.entriesForTesting().isEmpty)

        let retry = try harness.deliver(samples)
        #expect(Set(retry.events.values.map(\.sequence.rawValue)) == ["1", "2", "3"])
    }

    /// G12: a reset mints a new instance numbering from one, forgets the old facts, and old receipts release nothing.
    @Test
    func resetMintsANewInstanceAndOrphansOldReceipts() throws {
        try withTemporaryDirectory { root in
            let harness = LedgerHarness(ledger: .inDirectory(root))
            let sample = LedgerHarness.steps(0)
            let before = try harness.deliver([sample, LedgerHarness.steps(1)])

            try harness.ledger.sequencer(accountDataGeneration: 0).reset()
            #expect(try harness.ledger.entriesForTesting().isEmpty)

            let after = try harness.deliver([sample])
            let event = try #require(after.events[sample.uuid])
            #expect(event.producerInstance != before.events[sample.uuid]?.producerInstance)
            #expect(event.sequence.rawValue == "1")

            before.receipt?.release()
            let redelivery = try harness.deliver([sample])
            #expect(redelivery.events[sample.uuid] == event)
            #expect(try harness.ledger.entryKeys(prefixedBy: "event/").count == 1)
        }
    }

    /// G13: forgetting the reservations made before a cutoff removes exactly those and the facts no remaining
    /// reservation references, and keeps the producer, so later sequences continue under the same instance.
    @Test
    func forgetReservationsRemovesOnlyOlderReservationsAndUnreferencedFacts() throws {
        try withTemporaryDirectory { root in
            let harness = LedgerHarness(ledger: .inDirectory(root))
            let older = LedgerHarness.steps(0)
            let newer = LedgerHarness.steps(1)
            _ = try harness.deliver([older], at: LedgerHarness.start)
            let kept = try harness.deliver([newer], at: LedgerHarness.start + 3600)
            let producer = try harness.ledger.producerEntry()
            let sequencer = harness.ledger.sequencer(accountDataGeneration: 0)

            #expect(try sequencer.forgetReservations(madeBefore: LedgerHarness.start + 1800) == 1)
            #expect(try harness.ledger.entryKeys(prefixedBy: "event/").count == 1)
            #expect(try harness.ledger.entryKeys(prefixedBy: "facts/").count == 1)
            #expect(try harness.deliver([newer]).events == kept.events)

            #expect(try sequencer.forgetReservations(madeBefore: LedgerHarness.start + 7200) == 1)
            #expect(try harness.ledger.entryKeys(prefixedBy: "event/").isEmpty)
            #expect(try harness.ledger.entryKeys(prefixedBy: "facts/").isEmpty)
            let current = try harness.ledger.producerEntry()
            #expect(current.instance == producer.instance)
            #expect(current.next == producer.next)

            let redelivered = try #require(try harness.deliver([older]).events[older.uuid])
            #expect(redelivered.producerInstance == producer.instance)
            #expect(redelivered.sequence.rawValue == producer.next)
        }
    }
}
