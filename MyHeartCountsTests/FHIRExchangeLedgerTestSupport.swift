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
import Synchronization
import Testing

// The ledger tests' shared fixtures intentionally live in one file.
// swiftlint:disable file_types_order

/// A device-token store in memory, standing in for the keychain.
final class InMemoryDeviceBinding: FHIRExchangeLedgerDeviceBinding {
    private let token: Mutex<Data?>

    var storedToken: Data? {
        token.withLock { $0 }
    }

    init(token: Data? = nil) {
        self.token = Mutex(token)
    }

    func deviceToken() throws -> Data {
        token.withLock { stored in
            if let stored {
                return stored
            }
            let token = FHIRExchangeLedger.newDeviceToken()
            stored = token
            return token
        }
    }
}


/// Account preferences of the test's own, set by the test, which a ledger's live fence reads as it reads the
/// standard ones.
final class TestAccountPreferences: Sendable {
    private let suiteName = "edu.stanford.MyHeartCounts.unitTests.ledgerAccount.\(UUID().uuidString)"
    let store: LocalPreferencesStore

    /// The fence production builds over these preferences.
    var fence: FHIRExchangeLedger.AccountFence {
        .preferences(store)
    }

    init(generation: Int = 0) {
        // A suite name never equals the app's identifier, so `UserDefaults(suiteName:)` always returns one.
        store = LocalPreferencesStore(defaults: UserDefaults(suiteName: suiteName)!) // swiftlint:disable:this force_unwrapping
        store[.accountDataGeneration] = generation
    }

    func set(generation: Int? = nil, cleanupPending: Bool) {
        if let generation {
            store[.accountDataGeneration] = generation
        }
        store[.pendingAccountDataCleanupRequired] = cleanupPending
    }

    deinit {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }
}


/// What one export call delivered, by source sample.
struct LedgerDelivery {
    var events: [UUID: ExchangeEventIdentifier] = [:]
    var graphs: [UUID: Data] = [:]
    var receipt: HealthKitFHIRExporter.Receipt?
}


/// One installation's exchange inputs over a ledger under test; every account generation shares its identity secret.
struct LedgerHarness {
    static let start = Date(timeIntervalSince1970: 1_788_000_000)

    static var subject: FHIRExchangeSubject {
        get throws {
            try FHIRExchangeSubject(identity: BusinessIdentifier(
                system: FHIRExchangeIdentifiers.participant,
                value: "ledger-participant"
            ))
        }
    }

    let identity: FHIRExchangeStateStore
    let ledger: FHIRExchangeLedger

    init(identity: FHIRExchangeStateStore = FHIRExchangeStateStore(), ledger: FHIRExchangeLedger) {
        self.identity = identity
        self.ledger = ledger
    }

    /// A distinct step-count sample per index.
    static func steps(_ index: Int) -> HKQuantitySample {
        let sampleStart = start.addingTimeInterval(TimeInterval(index) * 60)
        return HKQuantitySample(
            type: HKQuantityType(.stepCount),
            quantity: HKQuantity(unit: .count(), doubleValue: Double(index + 1)),
            start: sampleStart,
            end: sampleStart.addingTimeInterval(30)
        )
    }

    func exporter(generation: Int = 0, subject: FHIRExchangeSubject? = nil) throws -> HealthKitFHIRExporter {
        try FHIRExchangeStateStore(accountDataGeneration: generation, secretsSharedWith: identity)
            .healthKitExporter(subject: subject ?? Self.subject, ledger: ledger)
    }

    /// Exports `samples` through a fresh exporter of `generation`.
    func deliver(_ samples: [HKSample], generation: Int = 0, at instant: Date = start) throws -> LedgerDelivery {
        try exporter(generation: generation).deliver(samples, at: instant)
    }
}


extension HealthKitFHIRExporter {
    func deliver(_ samples: [HKSample], at instant: Date = LedgerHarness.start) throws -> LedgerDelivery {
        var delivery = LedgerDelivery()
        delivery.receipt = try export(samples, at: instant) { export in
            guard let graph = export.graph else {
                return
            }
            delivery.events[export.source.uuid] = graph.eventIdentifier
            delivery.graphs[export.source.uuid] = graph.json
        }
        return delivery
    }
}


extension FHIRExchangeLedger {
    var directory: URL? {
        guard case .directory(let directory) = location else {
            return nil
        }
        return directory
    }

    /// A ledger in a directory of its own below `root`, bound to `binding` and fenced by `preferences`.
    static func inDirectory(
        _ root: URL,
        binding: InMemoryDeviceBinding = InMemoryDeviceBinding(),
        preferences: TestAccountPreferences = TestAccountPreferences()
    ) -> FHIRExchangeLedger {
        FHIRExchangeLedger(
            location: .directory(root.appending(path: "FHIRExchangeLedger", directoryHint: .isDirectory)),
            deviceBinding: binding,
            fence: preferences.fence
        )
    }

    /// The decoded JSON of one stored entry.
    func jsonEntry(_ key: String) throws -> [String: Any] {
        let value = try #require(try entriesForTesting()[key])
        return try #require(try JSONSerialization.jsonObject(with: value) as? [String: Any])
    }

    func entryKeys(prefixedBy prefix: String) throws -> [String] {
        try entriesForTesting().keys.filter { $0.hasPrefix(prefix) }.sorted()
    }

    /// The producer instance and next sequence the `producer` entry states.
    func producerEntry() throws -> (instance: UUID, next: String) {
        let producer = try jsonEntry("producer")
        let instanceText = try #require(producer["instance"] as? String)
        let instance = try #require(UUID(uuidString: instanceText))
        return (instance, try #require(producer["next"] as? String))
    }

    func setRawEntry(_ value: Data, for key: String) throws {
        try withDatabaseForTesting { db in
            try db.execute(sql: "UPDATE ledgerEntry SET value = ? WHERE key = ?", arguments: [value, key])
        }
    }

    func setJSONEntry(_ json: [String: Any], for key: String) throws {
        try setRawEntry(JSONSerialization.data(withJSONObject: json, options: [.sortedKeys, .withoutEscapingSlashes]), for: key)
    }

    func removeRawEntry(_ key: String) throws {
        try withDatabaseForTesting { db in
            try db.execute(sql: "DELETE FROM ledgerEntry WHERE key = ?", arguments: [key])
        }
    }

    func storedDeviceToken() throws -> Data? {
        try withDatabaseForTesting { db in
            try Data.fetchOne(db, sql: "SELECT deviceToken FROM ledgerMeta WHERE singleton = 1")
        }
    }

    func storedAccountGeneration() throws -> Int? {
        try withDatabaseForTesting { db in
            try Row.fetchOne(db, sql: "SELECT accountDataGeneration FROM ledgerMeta WHERE singleton = 1")
                .flatMap { $0["accountDataGeneration"] as Int? }
        }
    }
}


/// Runs `body` with a fresh temporary directory, removed afterwards, even when `body` locked it.
func withTemporaryDirectory<R>(_ body: (URL) throws -> R) throws -> R {
    let root = URL.temporaryDirectory.appending(path: "FHIRExchangeLedgerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path(percentEncoded: false))
        try? FileManager.default.removeItem(at: root)
    }
    return try body(root)
}


/// A deterministic random source, so a failing interleaving can be replayed.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
