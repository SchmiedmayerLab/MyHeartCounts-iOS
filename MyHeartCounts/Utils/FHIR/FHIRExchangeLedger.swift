//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GRDB
import Grove
import GroveFHIRContract
import GroveFoundation
import OSLog


/// MHC's exchange-event ledger: Grove's sequencer entries in their own SQLite database, bound to this
/// device and fenced to the live account generation.
///
/// It is the storage behind every HealthKit exporter (``sequencer(accountDataGeneration:)``) and meets
/// Grove's storage contract as follows:
/// - atomicity: every Grove transaction is one SQLite transaction, rolled back when its body throws;
/// - durability: a rollback journal with `synchronous = FULL` and `fullfsync = ON`, so a commit has
///   reached the device's storage, not only its cache, when it returns;
/// - isolation: one lazily opened connection, a lock around each transaction, and `BEGIN IMMEDIATE`;
/// - no regression or duplication: the directory is excluded from backup, and the database is bound
///   to a token in this device's keychain, so a copy restored or migrated elsewhere starts empty;
/// - byte-exactness: keys and values are stored as Grove's text and bytes, compared with `BINARY`.
///
/// Creating a ledger touches nothing; the database is opened by the first transaction, and a failed
/// open is retried by the next one. A corrupt database is deleted with its directory, as losing every
/// entry is always allowed; any other failure keeps the file and fails the call, so the caller keeps
/// its source anchors and redelivers.
final class FHIRExchangeLedger: Module, DefaultInitializable, Sendable {
    /// Where the database lives.
    enum Location: Sendable {
        /// `ledger.sqlite` in this directory, which belongs to the ledger alone: it is excluded from backup,
        /// and deleted whole when the database is corrupt.
        case directory(URL)
        /// A database in memory, without a file or a device binding, for tests and the unit-test host.
        case inMemory

        /// `Application Support/FHIRExchangeLedger`.
        static var `default`: Self {
            .directory(URL.applicationSupportDirectory.appending(path: "FHIRExchangeLedger", directoryHint: .isDirectory))
        }
    }

    /// The live account fence. Injected so tests exercise it without the global preferences.
    struct AccountFence: Sendable {
        static let live = Self(
            currentGeneration: { LocalPreferencesStore.standard[.accountDataGeneration] },
            cleanupPending: { LocalPreferencesStore.standard[.pendingAccountDataCleanupRequired] }
        )

        /// The account generation of the signed-in account.
        var currentGeneration: @Sendable () -> Int
        /// Whether the previous account's data still awaits its cleanup.
        var cleanupPending: @Sendable () -> Bool

        /// Refuses a writer whose generation has rotated, and every writer while cleanup is pending.
        func validate(_ captured: Int) throws {
            try FHIRExchangeDestination.validateWrites(
                for: captured,
                currentGeneration: currentGeneration(),
                cleanupPending: cleanupPending()
            )
        }
    }

    /// The database, opened by the first transaction; `lock` is held for every transaction from open to commit.
    private final class Connection: @unchecked Sendable { // `queue` is guarded by `lock`.
        let lock = NSLock()
        var queue: DatabaseQueue?
    }

    static let databaseFileName = "ledger.sqlite"

    let location: Location
    let deviceBinding: any FHIRExchangeLedgerDeviceBinding
    let fence: AccountFence
    private let connection = Connection()

    /// A ledger at `location`; nothing is opened until the first transaction.
    nonisolated init(
        location: Location,
        deviceBinding: any FHIRExchangeLedgerDeviceBinding = .keychain,
        fence: AccountFence = .live
    ) {
        self.location = location
        self.deviceBinding = deviceBinding
        self.fence = fence
    }

    /// The production ledger in `Application Support`.
    nonisolated convenience init() {
        self.init(location: .default)
    }

    /// A sequencer whose every transaction is fenced to `accountDataGeneration`.
    ///
    /// A transaction fails before it writes when the live generation differs or cleanup is pending. When
    /// the ledger still belongs to another generation, it is emptied and adopts this one first. When a
    /// stored entry is corrupt or from a later layout, the ledger is emptied (fenced the same way) and
    /// Grove's `LedgerError` is rethrown, so the redelivery starts on a fresh producer instance.
    func sequencer(accountDataGeneration: Int) -> ExchangeEventSequencer {
        ExchangeEventSequencer(storage: FencedStorage(ledger: self, accountDataGeneration: accountDataGeneration))
    }

    /// Account cleanup: removes every entry and records `generation` as the ledger's account generation.
    ///
    /// Not live-fenced, as cleanup is pending while it runs; the preferences rotate the generation first.
    func reset(toAccountDataGeneration generation: Int) throws {
        try write { db in
            try db.execute(sql: "DELETE FROM ledgerEntry")
            try db.execute(
                sql: "UPDATE ledgerMeta SET accountDataGeneration = ? WHERE singleton = 1",
                arguments: [generation]
            )
            try db.execute(sql: "PRAGMA incremental_vacuum")
        }
    }

    /// Recovery from Grove's `ExchangeEventSequencer.LedgerError`: removes every entry in a transaction
    /// live-fenced to `captured`, so a writer whose generation has rotated changes nothing.
    func recover(accountDataGeneration captured: Int) throws {
        try write { db in
            try fence.validate(captured)
            try Self.adoptAccountGeneration(captured, in: db)
            try db.execute(sql: "DELETE FROM ledgerEntry")
            try db.execute(sql: "PRAGMA incremental_vacuum")
        }
    }

    /// Runs one Grove transaction fenced to `captured`.
    fileprivate func transaction<R>(
        fencedTo captured: Int,
        _ body: (any ExchangeEventSequencer.Transaction) throws -> R
    ) throws -> R {
        try write { db in
            try fence.validate(captured)
            try Self.adoptAccountGeneration(captured, in: db)
            let transaction = LedgerTransaction(db: db)
            defer {
                transaction.close()
            }
            return try body(transaction)
        }
    }

    /// Runs `body` as one `BEGIN IMMEDIATE` transaction, opening the database first when needed.
    ///
    /// A corrupt database is closed and deleted before the error is rethrown.
    private func write<R>(_ body: (Database) throws -> R) throws -> R {
        connection.lock.lock()
        defer {
            connection.lock.unlock()
        }
        do {
            let queue = try openedQueue()
            return try queue.writeWithoutTransaction { db in
                var result: R?
                try db.inTransaction(.immediate) {
                    result = try body(db)
                    return .commit
                }
                guard let result else {
                    preconditionFailure("A committed ledger transaction always produced its result.")
                }
                return result
            }
        } catch {
            if Self.isCorruption(error) {
                discardDatabase(after: error)
            }
            throw error
        }
    }

    /// The open database; requires `connection.lock`.
    private func openedQueue() throws -> DatabaseQueue {
        if let queue = connection.queue {
            return queue
        }
        let queue = try open()
        connection.queue = queue
        return queue
    }

    private func open() throws -> DatabaseQueue {
        switch location {
        case .inMemory:
            let queue = try DatabaseQueue(configuration: Self.configuration)
            try Self.migrator.migrate(queue)
            try Self.bind(queue, toDeviceToken: Self.newDeviceToken())
            return queue
        case .directory(let directory):
            try Self.prepare(directory: directory)
            let file = directory.appending(path: Self.databaseFileName, directoryHint: .notDirectory)
            let queue = try DatabaseQueue(path: file.path(percentEncoded: false), configuration: Self.configuration)
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: file.path(percentEncoded: false)
            )
            try Self.migrator.migrate(queue)
            try Self.bind(queue, toDeviceToken: deviceBinding.deviceToken())
            return queue
        }
    }

    /// Closes the connection and deletes the ledger's directory; the next transaction starts on an empty ledger.
    ///
    /// Requires `connection.lock`.
    private func discardDatabase(after error: any Error) {
        logger.error("Discarding the corrupt FHIR exchange ledger: \(error)")
        if let queue = connection.queue {
            try? queue.close()
        }
        connection.queue = nil
        guard case .directory(let directory) = location else {
            return
        }
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            logger.error("Unable to delete the corrupt FHIR exchange ledger: \(error)")
        }
    }
}


extension FHIRExchangeLedger {
    /// The ledger as Grove's sequencer sees it: every transaction is fenced to one account generation.
    private struct FencedStorage: ExchangeEventSequencer.Storage {
        let ledger: FHIRExchangeLedger
        let accountDataGeneration: Int

        func transaction<R>(_ body: (any ExchangeEventSequencer.Transaction) throws -> R) throws -> R {
            do {
                return try ledger.transaction(fencedTo: accountDataGeneration, body)
            } catch let error as ExchangeEventSequencer.LedgerError {
                logger.error("The FHIR exchange ledger holds an entry Grove refuses (\(String(describing: error))); emptying it")
                do {
                    try ledger.recover(accountDataGeneration: accountDataGeneration)
                } catch {
                    logger.error("Unable to empty the FHIR exchange ledger: \(error)")
                }
                throw error
            }
        }
    }
}


#if DEBUG
extension FHIRExchangeLedger {
    /// An isolated in-memory ledger whose fence always reports `accountDataGeneration` and no pending cleanup.
    static func forTesting(accountDataGeneration: Int = 0) -> FHIRExchangeLedger {
        FHIRExchangeLedger(
            location: .inMemory,
            fence: AccountFence(currentGeneration: { accountDataGeneration }, cleanupPending: { false })
        )
    }

    /// Runs `body` on the ledger's own connection, outside any transaction and unfenced, opening it when needed.
    func withDatabaseForTesting<R>(_ body: (Database) throws -> R) throws -> R {
        connection.lock.lock()
        defer {
            connection.lock.unlock()
        }
        return try openedQueue().writeWithoutTransaction(body)
    }

    /// Every stored entry, read unfenced.
    func entriesForTesting() throws -> [String: Data] {
        try withDatabaseForTesting { db in
            try Dictionary(uniqueKeysWithValues: Row.fetchAll(db, sql: "SELECT key, value FROM ledgerEntry").map { row in
                (row["key"] as String, row["value"] as Data)
            })
        }
    }

    /// Closes the connection, as terminating the process would; the next transaction opens it again.
    func closeForTesting() throws {
        connection.lock.lock()
        defer {
            connection.lock.unlock()
        }
        try connection.queue?.close()
        connection.queue = nil
    }
}
#endif
