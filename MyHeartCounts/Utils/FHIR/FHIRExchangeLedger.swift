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
import Grove
import GroveFHIRContract
import GroveFoundation
import OSLog
import Synchronization


/// MHC's exchange-event ledger: Grove's ledger entries in their own SQLite database, bound to this
/// device and fenced to the live account generation.
///
/// It is the storage behind every exchange producer (``storage(accountDataGeneration:)``) and meets
/// Grove's storage contract as follows:
/// - atomicity: every Grove transaction is one SQLite transaction, rolled back when its body throws;
/// - durability: a rollback journal with `synchronous = FULL` and `fullfsync = ON`, so a commit has
///   reached the device's storage, not only its cache, when it returns;
/// - isolation: every ledger over one directory in this process shares one lazily opened connection, with
///   a lock around each transaction and `BEGIN IMMEDIATE`; while that connection is open it holds an
///   exclusive lock on a file beside the directory, so no other process opens the database meanwhile;
/// - no regression or duplication: the directory is excluded from backup, and the database is bound
///   to a token in this device's keychain, so a copy restored or migrated elsewhere starts empty;
/// - byte-exactness: keys and values are stored as Grove's text and bytes, compared with `BINARY`.
///
/// Creating a ledger touches nothing; the database is opened by the first transaction, and a failed
/// open is retried by the next one. A corrupt database is deleted with its directory, as losing every
/// entry is always allowed, and only while no other connection can use it; any other failure keeps the
/// file and fails the call, so the caller keeps its source anchors and redelivers.
final class FHIRExchangeLedger: Module, DefaultInitializable, Sendable {
    /// Where the database lives.
    enum Location: Sendable {
        /// `ledger.sqlite` in this directory, which belongs to the ledger alone: it is excluded from backup,
        /// and deleted whole when the database is corrupt. The lock file `<directory>.lock` beside it is never
        /// deleted.
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
        static let live = Self.preferences(.standard)

        /// The account generation of the signed-in account.
        var currentGeneration: @Sendable () -> Int
        /// Whether the previous account's data still awaits its cleanup.
        var cleanupPending: @Sendable () -> Bool

        /// The fence `preferences` state: their account generation, and whether cleanup is pending.
        static func preferences(_ preferences: LocalPreferencesStore) -> Self {
            Self(
                currentGeneration: { preferences[.accountDataGeneration] },
                cleanupPending: { preferences[.pendingAccountDataCleanupRequired] }
            )
        }

        /// Refuses a writer whose generation has rotated, and every writer while cleanup is pending.
        func validate(_ captured: Int) throws {
            try FHIRExchangeDestination.validateWrites(
                for: captured,
                currentGeneration: currentGeneration(),
                cleanupPending: cleanupPending()
            )
        }
    }

    /// Why a ledger cannot open its database.
    enum OwnershipError: Error, Equatable {
        /// Another process has the directory's database open; a later call opens it once that process lets go.
        case directoryInUse
    }

    /// The database of one location, opened by the first transaction; `lock` is held for every transaction
    /// from open to commit.
    ///
    /// Every ledger over one directory in this process shares its connection (see ``connection(for:)``), so
    /// discarding a corrupt database never leaves another ledger of this process on the deleted file.
    private final class Connection: @unchecked Sendable { // `queue` and `ownership` are guarded by `lock`.
        let lock = NSLock()
        var queue: DatabaseQueue?
        /// The exclusive claim on the directory, held from before the database is opened until it is closed.
        var ownership: DirectoryOwnership?
    }

    /// An exclusive `flock` on ``lockFile(for:)``, which lives outside the directory and is never deleted.
    ///
    /// Every connection takes it before it opens the database, so while one is open no other process opens
    /// that database, and a discard never deletes a file another connection still uses.
    private final class DirectoryOwnership {
        private var descriptor: Int32

        init(of directory: URL) throws {
            let file = FHIRExchangeLedger.lockFile(for: directory)
            let path = file.path(percentEncoded: false)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: path) {
                // Readable while the device is locked after its first unlock, as the database is.
                FileManager.default.createFile(
                    atPath: path,
                    contents: nil,
                    attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
                )
            }
            let descriptor = Darwin.open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                let code = errno
                Darwin.close(descriptor)
                if code == EWOULDBLOCK {
                    throw OwnershipError.directoryInUse
                }
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
            self.descriptor = descriptor
        }

        /// Gives up the claim; closing the descriptor releases the lock.
        func release() {
            guard descriptor >= 0 else {
                return
            }
            Darwin.close(descriptor)
            descriptor = -1
        }

        deinit {
            release()
        }
    }

    private struct WeakConnection {
        weak var connection: Connection?
    }

    /// The connection of every directory a ledger of this process uses, held weakly.
    private static let sharedConnections = Mutex<[String: WeakConnection]>([:])

    static let databaseFileName = "ledger.sqlite"

    let location: Location
    let deviceBinding: any FHIRExchangeLedgerDeviceBinding
    let fence: AccountFence
    private let connection: Connection

    /// A ledger at `location`; nothing is opened until the first transaction.
    nonisolated init(
        location: Location,
        deviceBinding: any FHIRExchangeLedgerDeviceBinding = .keychain,
        fence: AccountFence = .live
    ) {
        self.location = location
        self.deviceBinding = deviceBinding
        self.fence = fence
        self.connection = Self.connection(for: location)
    }

    /// The production ledger in `Application Support`.
    nonisolated convenience init() {
        self.init(location: .default)
    }

    /// The lock file of the ledger in `directory`: `<directory>.lock`, beside the directory.
    static func lockFile(for directory: URL) -> URL {
        directory.deletingLastPathComponent().appending(path: "\(directory.lastPathComponent).lock", directoryHint: .notDirectory)
    }

    /// The connection `location` is opened through: one per directory in this process, shared by every ledger
    /// over it, and one of its own for each in-memory ledger.
    ///
    /// The ledgers sharing a connection share its device binding too: whichever opens the database first binds it.
    private static func connection(for location: Location) -> Connection {
        guard case .directory(let directory) = location else {
            return Connection()
        }
        var key = directory.standardizedFileURL.path(percentEncoded: false)
        while key.count > 1 && key.hasSuffix("/") {
            key.removeLast()
        }
        return sharedConnections.withLock { connections in
            if let shared = connections[key]?.connection {
                return shared
            }
            connections = connections.filter { $0.value.connection != nil }
            let connection = Connection()
            connections[key] = WeakConnection(connection: connection)
            return connection
        }
    }

    /// The ledger as an exchange producer's storage, every transaction fenced to `accountDataGeneration`.
    ///
    /// A transaction fails before it writes when the live generation differs or cleanup is pending. When
    /// the ledger still belongs to another generation, it is emptied and adopts this one first. When a
    /// stored entry is corrupt or from a later layout, the ledger is emptied (fenced the same way) and
    /// Grove's `LedgerError` is rethrown, so the redelivery starts on a fresh producer instance.
    func storage(accountDataGeneration: Int) -> any ExchangeProducer.Storage {
        FencedStorage(ledger: self, accountDataGeneration: accountDataGeneration)
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

    /// Recovery from Grove's `ExchangeProducer.LedgerError`: removes every entry in a transaction
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
        _ body: (any ExchangeProducer.Transaction) throws -> R
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
    /// A corrupt database is closed and deleted before the error is rethrown; a failed open gives up the directory.
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
            } else if connection.queue == nil {
                closeConnection()
            }
            throw error
        }
    }

    /// The open database, claiming the directory before opening it; requires `connection.lock`.
    private func openedQueue() throws -> DatabaseQueue {
        if let queue = connection.queue {
            return queue
        }
        if connection.ownership == nil, case .directory(let directory) = location {
            connection.ownership = try DirectoryOwnership(of: directory)
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

    /// Closes the database and gives up the directory; requires `connection.lock`.
    private func closeConnection() {
        try? connection.queue?.close()
        connection.queue = nil
        connection.ownership?.release()
        connection.ownership = nil
    }

    /// Closes the connection and deletes the ledger's directory before giving it up, so no other connection
    /// opens the deleted file meanwhile; the next transaction starts on an empty ledger.
    ///
    /// Requires `connection.lock`.
    private func discardDatabase(after error: any Error) {
        logger.error("Discarding the corrupt FHIR exchange ledger: \(error)")
        try? connection.queue?.close()
        connection.queue = nil
        if case .directory(let directory) = location {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                logger.error("Unable to delete the corrupt FHIR exchange ledger: \(error)")
            }
        }
        closeConnection()
    }
}


extension FHIRExchangeLedger {
    /// The ledger as Grove's producer sees it: every transaction is fenced to one account generation.
    private struct FencedStorage: ExchangeProducer.Storage {
        let ledger: FHIRExchangeLedger
        let accountDataGeneration: Int

        func transaction<R>(_ body: (any ExchangeProducer.Transaction) throws -> R) throws -> R {
            do {
                return try ledger.transaction(fencedTo: accountDataGeneration, body)
            } catch let error as ExchangeProducer.LedgerError {
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
        do {
            return try openedQueue().writeWithoutTransaction(body)
        } catch {
            if connection.queue == nil {
                closeConnection()
            }
            throw error
        }
    }

    /// Every stored entry, read unfenced.
    func entriesForTesting() throws -> [String: Data] {
        try withDatabaseForTesting { db in
            try Dictionary(uniqueKeysWithValues: Row.fetchAll(db, sql: "SELECT key, value FROM ledgerEntry").map { row in
                (row["key"] as String, row["value"] as Data)
            })
        }
    }

    /// Closes the connection and gives up the directory, as terminating the process would; the next transaction
    /// opens it again.
    func closeForTesting() throws {
        connection.lock.lock()
        defer {
            connection.lock.unlock()
        }
        try connection.queue?.close()
        closeConnection()
    }
}
#endif
