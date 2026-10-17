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
import OSLog


extension FHIRExchangeLedger {
    /// A write-ahead log with fully synchronous, device-flushed commits.
    ///
    /// WAL is set up here rather than through GRDB's `journalMode = .wal`, which lowers `synchronous` to `NORMAL`
    /// after `prepareDatabase` ran (seen in GRDB 7.11.1's `Database.setUpWALMode()`; its documentation only names
    /// "extra configurations"): a commit must survive power loss before its sequence leaves the device, and in WAL
    /// mode `synchronous = FULL` syncs the log at every commit. An existing database switches to WAL when
    /// it is next opened; the process-exclusive lock guarantees no other connection holds it.
    static var configuration: Configuration {
        var configuration = Configuration()
        configuration.label = "FHIRExchangeLedger"
        configuration.journalMode = .default
        configuration.busyMode = .timeout(10)
        configuration.prepareDatabase { db in
            // Effective only before the first table exists, so it sticks to a database created here.
            try db.execute(sql: "PRAGMA auto_vacuum = INCREMENTAL")
            _ = try String.fetchOne(db, sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA synchronous = FULL")
            try db.execute(sql: "PRAGMA fullfsync = ON")
            try db.execute(sql: "PRAGMA checkpoint_fullfsync = ON")
        }
        return configuration
    }

    /// The ledger's schema: Grove's entries, and one metadata row with the device token and the account
    /// generation the entries belong to.
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "ledgerMeta", options: .strict) { table in
                table.primaryKey("singleton", .integer).check { $0 == 1 }
                table.column("deviceToken", .blob).notNull()
                // NULL until the first fenced transaction adopts one.
                table.column("accountDataGeneration", .integer)
            }
            // An ordinary rowid table: facts values can reach 1 MiB, which WITHOUT ROWID suits poorly.
            try db.create(table: "ledgerEntry", options: .strict) { table in
                table.column("key", .text).notNull().unique()
                table.column("value", .blob).notNull()
            }
        }
        return migrator
    }

    static func isCorruption(_ error: any Error) -> Bool {
        guard let error = error as? DatabaseError else {
            return false
        }
        return error.resultCode == .SQLITE_CORRUPT || error.resultCode == .SQLITE_NOTADB
    }

    static func newDeviceToken() -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    /// Creates the directory, excludes it from backup (covering every file created in it later), and
    /// keeps it readable while the device is locked after its first unlock.
    static func prepare(directory: URL) throws {
        let protection: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: protection)
        try FileManager.default.setAttributes(protection, ofItemAtPath: directory.path(percentEncoded: false))
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var directory = directory
        try directory.setResourceValues(resourceValues)
    }

    /// Binds the database to `deviceToken`; a database bound to another token, or holding entries without
    /// any, came from elsewhere and is emptied first.
    static func bind(_ queue: DatabaseQueue, toDeviceToken deviceToken: Data) throws {
        try queue.inTransaction(.immediate) { db in
            let stored = try Data.fetchOne(db, sql: "SELECT deviceToken FROM ledgerMeta WHERE singleton = 1")
            guard stored != deviceToken else {
                return .commit
            }
            if try stored != nil || Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ledgerEntry") != 0 {
                logger.notice("The FHIR exchange ledger is not bound to this device; discarding its entries")
            }
            try db.execute(sql: "DELETE FROM ledgerEntry")
            try db.execute(
                sql: "INSERT OR REPLACE INTO ledgerMeta (singleton, deviceToken, accountDataGeneration) VALUES (1, ?, NULL)",
                arguments: [deviceToken]
            )
            return .commit
        }
    }

    /// The stored fence: a ledger without a generation adopts `captured`, and one that still belongs to
    /// another generation is emptied and adopts it.
    ///
    /// Runs after the live fence inside the write lock, so `captured` is the live generation and no cleanup
    /// is pending; this also heals a stored generation ahead of the live one, such as after lost preferences.
    static func adoptAccountGeneration(_ captured: Int, in db: Database) throws {
        let stored = try Row.fetchOne(db, sql: "SELECT accountDataGeneration FROM ledgerMeta WHERE singleton = 1")
            .flatMap { $0["accountDataGeneration"] as Int? }
        guard stored != captured else {
            return
        }
        if let stored {
            logger.notice("The FHIR exchange ledger belongs to account generation \(stored); emptying it for generation \(captured)")
            try db.execute(sql: "DELETE FROM ledgerEntry")
        }
        try db.execute(
            sql: "UPDATE ledgerMeta SET accountDataGeneration = ? WHERE singleton = 1",
            arguments: [captured]
        )
    }
}


extension FHIRExchangeLedger {
    /// One SQLite transaction's view of the ledger, through cached statements.
    final class LedgerTransaction: ExchangeProducer.Transaction {
        private static let readSQL = "SELECT value FROM ledgerEntry WHERE key = ?"
        private static let writeSQL = "INSERT INTO ledgerEntry (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value"
        private static let removeSQL = "DELETE FROM ledgerEntry WHERE key = ?"
        /// Grove's keys are ASCII below 0x7F, so the keys with a prefix are exactly the range up to `prefix || char(127)`.
        private static let keysSQL = "SELECT key FROM ledgerEntry WHERE key >= ? AND key < ? || char(127)"

        private let db: Database
        private var isOpen = true

        init(db: Database) {
            self.db = db
        }

        func read(_ key: String) throws -> Data? {
            precondition(isOpen, "A ledger transaction is used only inside its body.")
            return try Data.fetchOne(db.cachedStatement(sql: Self.readSQL), arguments: [key])
        }

        func write(_ value: Data, for key: String) throws {
            precondition(isOpen, "A ledger transaction is used only inside its body.")
            try db.cachedStatement(sql: Self.writeSQL).execute(arguments: [key, value])
        }

        func remove(_ key: String) throws {
            precondition(isOpen, "A ledger transaction is used only inside its body.")
            try db.cachedStatement(sql: Self.removeSQL).execute(arguments: [key])
        }

        func keys(prefixedBy prefix: String) throws -> [String] {
            precondition(isOpen, "A ledger transaction is used only inside its body.")
            return try String.fetchAll(db.cachedStatement(sql: Self.keysSQL), arguments: [prefix, prefix])
        }

        func close() {
            isOpen = false
        }
    }
}
