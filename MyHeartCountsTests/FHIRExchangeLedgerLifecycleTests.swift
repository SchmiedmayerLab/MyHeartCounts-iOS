//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Darwin
import Foundation
import GRDB
import GroveFHIRContract
import HealthKit
@testable import MyHeartCounts
import Testing


/// How the ledger's database is configured, opened, bound to the device, and discarded.
@Suite
struct FHIRExchangeLedgerLifecycleTests {
    /// The ledger's lock file as another process sees it: a descriptor of its own, locked and unlocked by the test.
    private final class ForeignLockHolder {
        private let descriptor: Int32

        init(of directory: URL) throws {
            let path = FHIRExchangeLedger.lockFile(for: directory).path(percentEncoded: false)
            descriptor = Darwin.open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
            try #require(descriptor >= 0)
        }

        func tryLock() -> Bool {
            flock(descriptor, LOCK_EX | LOCK_NB) == 0
        }

        func unlock() {
            flock(descriptor, LOCK_UN)
        }

        deinit {
            Darwin.close(descriptor)
        }
    }

    /// Overwrites the pages of `ledgerEntry` and its key index behind the open connection's back, and bumps the
    /// file change counter so the connection reads them again.
    private static func corruptLedgerEntryPages(of ledger: FHIRExchangeLedger) throws {
        let (pageSize, rootPages) = try ledger.withDatabaseForTesting { db in
            (
                try #require(try Int.fetchOne(db, sql: "PRAGMA page_size")),
                try Int.fetchAll(db, sql: "SELECT rootpage FROM sqlite_master WHERE tbl_name = 'ledgerEntry' AND rootpage > 0")
            )
        }
        let file = try #require(ledger.directory).appending(path: FHIRExchangeLedger.databaseFileName)
        let handle = try FileHandle(forUpdating: file)
        defer {
            try? handle.close()
        }
        for page in rootPages {
            try handle.seek(toOffset: UInt64((page - 1) * pageSize))
            try handle.write(contentsOf: Data(repeating: 0xFF, count: pageSize))
        }
        try handle.seek(toOffset: 24)
        let counter = try #require(try handle.read(upToCount: 4))
        let bumped = counter.reduce(UInt32(0)) { $0 << 8 | UInt32($1) } &+ 1
        try handle.seek(toOffset: 24)
        try handle.write(contentsOf: withUnsafeBytes(of: bumped.bigEndian) { Data($0) })
        try handle.synchronize()
    }

    /// M13: a commit reaches the device's storage, through a fully synchronous write-ahead log, before it returns.
    @Test
    func productionConfigurationIsFullyDurable() throws {
        try withTemporaryDirectory { root in
            let ledger = FHIRExchangeLedger.inDirectory(root)
            _ = try LedgerHarness(ledger: ledger).deliver([LedgerHarness.steps(0)])
            let journalMode = try ledger.withDatabaseForTesting { try String.fetchOne($0, sql: "PRAGMA journal_mode") }
            let synchronous = try ledger.withDatabaseForTesting { try Int.fetchOne($0, sql: "PRAGMA synchronous") }
            let fullFSync = try ledger.withDatabaseForTesting { try Int.fetchOne($0, sql: "PRAGMA fullfsync") }
            let checkpointFullFSync = try ledger.withDatabaseForTesting { try Int.fetchOne($0, sql: "PRAGMA checkpoint_fullfsync") }
            let autoVacuum = try ledger.withDatabaseForTesting { try Int.fetchOne($0, sql: "PRAGMA auto_vacuum") }

            #expect(journalMode == "wal")
            #expect(synchronous == 2)
            #expect(fullFSync == 1)
            #expect(checkpointFullFSync == 1)
            #expect(autoVacuum == 2)
            let directory = try #require(ledger.directory)
            let isExcluded = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
            // The log and its index live beside the database, so the directory's exclusion covers them too.
            #expect(isExcluded == true)
        }
    }

    /// M9d: the schema migrates once; migrating again changes nothing and keeps every entry.
    @Test
    func migratorIsIdempotent() throws {
        try withTemporaryDirectory { root in
            let binding = InMemoryDeviceBinding()
            let harness = LedgerHarness(ledger: .inDirectory(root, binding: binding))
            let sample = LedgerHarness.steps(0)
            let first = try harness.deliver([sample])
            let entries = try harness.ledger.entriesForTesting()
            try harness.ledger.closeForTesting()

            let file = try #require(harness.ledger.directory).appending(path: FHIRExchangeLedger.databaseFileName)
            let queue = try DatabaseQueue(path: file.path(percentEncoded: false), configuration: FHIRExchangeLedger.configuration)
            try FHIRExchangeLedger.migrator.migrate(queue)
            try FHIRExchangeLedger.migrator.migrate(queue)
            #expect(try queue.read { try FHIRExchangeLedger.migrator.appliedIdentifiers($0) } == ["v1"])
            try queue.close()

            let reopened = LedgerHarness(identity: harness.identity, ledger: .inDirectory(root, binding: binding))
            #expect(try reopened.ledger.entriesForTesting() == entries)
            #expect(try reopened.deliver([sample]).events == first.events)
        }
    }

    /// M14: creating the module touches nothing on disk.
    @Test
    func creatingTheLedgerCreatesNoFile() throws {
        try withTemporaryDirectory { root in
            let ledger = FHIRExchangeLedger.inDirectory(root)
            _ = ledger.storage(accountDataGeneration: 0)
            let files = try FileManager.default.contentsOfDirectory(atPath: root.path(percentEncoded: false))
            #expect(files.isEmpty)
        }
    }

    /// M14: a failed open fails the export, and a later export opens the ledger once it can.
    @Test
    func failedOpenIsRetriedByTheNextCall() throws {
        try withTemporaryDirectory { root in
            let harness = LedgerHarness(ledger: .inDirectory(root))
            let rootPath = root.path(percentEncoded: false)
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: rootPath)

            #expect(throws: (any Error).self) {
                try harness.deliver([LedgerHarness.steps(0)])
            }

            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: rootPath)
            let delivery = try harness.deliver([LedgerHarness.steps(0)])
            #expect(delivery.events.values.map(\.sequence.rawValue) == ["1"])
        }
    }

    /// M14: a page corrupted after the database was opened fails the transaction, the directory is discarded,
    /// and the next export starts over on a fresh producer instance.
    @Test
    func corruptPageDiscardsTheDatabase() throws {
        try withTemporaryDirectory { root in
            let harness = LedgerHarness(ledger: .inDirectory(root))
            let sample = LedgerHarness.steps(0)
            let first = try #require(try harness.deliver([sample]).events[sample.uuid])
            try Self.corruptLedgerEntryPages(of: harness.ledger)

            let error = #expect(throws: (any Error).self) {
                try harness.deliver([sample])
            }
            #expect(error.map(FHIRExchangeLedger.isCorruption) == true)
            let directory = try #require(harness.ledger.directory)
            #expect(!FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)))

            let next = try #require(try harness.deliver([sample]).events[sample.uuid])
            #expect(next.producerInstance != first.producerInstance)
            #expect(next.sequence.rawValue == "1")
        }
    }

    /// M14: a file that is not a database, found when the ledger opens, fails the call and is discarded with its
    /// directory, and the next export starts at sequence one.
    @Test
    func corruptFileFoundAtOpenIsDiscarded() throws {
        try withTemporaryDirectory { root in
            let harness = LedgerHarness(ledger: .inDirectory(root))
            let directory = try #require(harness.ledger.directory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(repeating: 0x42, count: 8192).write(to: directory.appending(path: FHIRExchangeLedger.databaseFileName))
            let sample = LedgerHarness.steps(0)

            let error = #expect(throws: (any Error).self) {
                try harness.deliver([sample])
            }
            #expect(error.map(FHIRExchangeLedger.isCorruption) == true)
            #expect(!FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)))

            let next = try #require(try harness.deliver([sample]).events[sample.uuid])
            #expect(next.sequence.rawValue == "1")
            #expect(try harness.ledger.producerEntry().instance == next.producerInstance)
        }
    }

    /// Two ledgers over one directory in this process share its connection: when one discards the corrupt
    /// database, the other continues on the replacement instead of on the deleted file.
    @Test
    func ledgersOverOneDirectoryContinueOnTheReplacementTogether() throws {
        try withTemporaryDirectory { root in
            let binding = InMemoryDeviceBinding()
            let first = LedgerHarness(ledger: .inDirectory(root, binding: binding))
            let second = LedgerHarness(identity: first.identity, ledger: .inDirectory(root, binding: binding))
            let sample = LedgerHarness.steps(0)
            let original = try #require(try first.deliver([sample]).events[sample.uuid])
            #expect(try second.deliver([sample]).events[sample.uuid] == original)
            try Self.corruptLedgerEntryPages(of: first.ledger)

            #expect(throws: (any Error).self) {
                try first.deliver([sample])
            }
            let replacement = try #require(try first.deliver([sample]).events[sample.uuid])
            #expect(replacement.producerInstance != original.producerInstance)

            let other = LedgerHarness.steps(1)
            let next = try #require(try second.deliver([other]).events[other.uuid])
            #expect(next.producerInstance == replacement.producerInstance)
            #expect(next.sequence.rawValue == "2")
            #expect(try first.ledger.entryKeys(prefixedBy: "event/").count == 2)
        }
    }

    /// While a connection has the database open, it holds the lock file beside the directory; a ledger whose lock
    /// file another process holds opens nothing and deletes nothing, and opens once that process lets go.
    @Test
    func directoryAnotherProcessHoldsIsNeitherOpenedNorDiscarded() throws {
        try withTemporaryDirectory { root in
            let harness = LedgerHarness(ledger: .inDirectory(root))
            let directory = try #require(harness.ledger.directory)
            let otherProcess = try ForeignLockHolder(of: directory)
            try #require(otherProcess.tryLock())

            #expect(throws: FHIRExchangeLedger.OwnershipError.directoryInUse) {
                try harness.deliver([LedgerHarness.steps(0)])
            }
            #expect(!FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)))

            otherProcess.unlock()
            let delivery = try harness.deliver([LedgerHarness.steps(0)])
            #expect(delivery.events.values.map(\.sequence.rawValue) == ["1"])
            #expect(!otherProcess.tryLock())

            try harness.ledger.closeForTesting()
            #expect(otherProcess.tryLock())
        }
    }
}
