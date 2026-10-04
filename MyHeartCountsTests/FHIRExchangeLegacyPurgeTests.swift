//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFHIRContract
import GroveFoundation
import GroveSensorKitFHIR
@testable import MyHeartCounts
import Testing


/// M9: the exchange events older builds kept in the encrypted state leave it once, best effort, after their SensorKit
/// retry digests were migrated; the ledger never depends on it.
@Suite
final class FHIRExchangeLegacyPurgeTests {
    private static let batchKey = "participant|SRSensor.deviceUsage|iPhone18,1|batch"
    private static let sourceRecordID = SensorKitSourceRecordID(UUID())

    private let suiteName = "edu.stanford.MyHeartCounts.unitTests.legacyPurge.\(UUID().uuidString)"
    private let preferences: LocalPreferencesStore

    init() throws {
        preferences = LocalPreferencesStore(defaults: try #require(UserDefaults(suiteName: suiteName)))
    }

    /// The state an older build stored: one SensorKit batch's retry digest of `"first"`, beside its own exchange
    /// events of every source, their producer instance and counter.
    private static func legacyState(accountDataGeneration: Int = 0) throws -> Data {
        let current = FHIRExchangeStateStore(accountDataGeneration: accountDataGeneration)
        try current.verifySensorRetryDigest(Data("first".utf8), batchKey: batchKey, sourceRecordID: sourceRecordID)
        var state = try decodedJSON(try #require(current.encodedStateForTesting))
        let event: [String: Any] = [
            "sequence": 1,
            "recordedAt": 810_000_000.5,
            "sourceTimeZoneIdentifier": "Europe/Berlin",
            "facts": [
                "applicationName": "My Heart Counts",
                "applicationBundleIdentifier": "edu.stanford.MyHeartCounts",
                "applicationVersion": "3.0",
                "hostOperatingSystemVersion": "26.0"
            ]
        ]
        state["schemaVersion"] = 0
        state["sensorBatches"] = nil
        state["producerInstance"] = UUID().uuidString
        state["nextEventSequence"] = 4
        state["events"] = [
            "healthkit|participant|HKQuantityTypeIdentifierStepCount|uuid": event,
            "sensorkit|\(batchKey)|\(sourceRecordID.value)": event,
            "questionnaire|participant|response": event
        ]
        return try JSONSerialization.data(withJSONObject: state)
    }

    private static func decodedJSON(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// M9a: an installation without encrypted state gets none, and HealthKit starts on an empty ledger.
    @Test
    func withoutLegacyStateTheLedgerStartsEmpty() throws {
        let store = FHIRExchangeStateStore()
        FHIRExchangeStateStore.purgeLegacyExchangeEventsOnce(in: store, preferences: preferences)

        #expect(preferences[.didPurgeLegacyExchangeEvents])
        #expect(store.encodedStateForTesting == nil)
        let ledger = FHIRExchangeLedger.forTesting()
        #expect(try ledger.entriesForTesting().isEmpty)
        let delivery = try LedgerHarness(identity: store, ledger: ledger).deliver([LedgerHarness.steps(0)])
        #expect(delivery.events.values.map(\.sequence.rawValue) == ["1"])
    }

    /// M9b: every event, the producer instance and its counter go; the retry digests stay, so a batch pending at the
    /// upgrade still fails closed on drift. A later launch does not purge again.
    @Test
    func purgeDropsTheEventsAndKeepsTheRetryDigests() throws {
        let store = FHIRExchangeStateStore(testingEncodedState: try Self.legacyState())

        FHIRExchangeStateStore.purgeLegacyExchangeEventsOnce(in: store, preferences: preferences)

        #expect(preferences[.didPurgeLegacyExchangeEvents])
        let purged = try Self.decodedJSON(try #require(store.encodedStateForTesting))
        #expect(Set(purged.keys) == ["schemaVersion", "accountDataGeneration", "sensorRetries", "sensorBatches"])
        #expect(purged["schemaVersion"] as? Int == 1)
        // Drift first: a dropped digest would record the changed bytes instead of refusing them.
        #expect(throws: FHIRExchangeStateError.retryContentChanged(sourceRecordID: Self.sourceRecordID.value)) {
            try store.verifySensorRetryDigest(Data("changed".utf8), batchKey: Self.batchKey, sourceRecordID: Self.sourceRecordID)
        }
        try store.verifySensorRetryDigest(Data("first".utf8), batchKey: Self.batchKey, sourceRecordID: Self.sourceRecordID)

        let later = FHIRExchangeStateStore(testingEncodedState: try Self.legacyState())
        FHIRExchangeStateStore.purgeLegacyExchangeEventsOnce(in: later, preferences: preferences)
        #expect(try Self.decodedJSON(try #require(later.encodedStateForTesting))["events"] != nil)
    }

    /// The retry digests migrate on every read, so a SensorKit batch pending at the upgrade is checked against them
    /// before the purge ever ran.
    @Test
    func retryDigestsMigrateBeforeThePurge() throws {
        let store = FHIRExchangeStateStore(testingEncodedState: try Self.legacyState())

        #expect(throws: FHIRExchangeStateError.retryContentChanged(sourceRecordID: Self.sourceRecordID.value)) {
            try store.verifySensorRetryDigest(Data("changed".utf8), batchKey: Self.batchKey, sourceRecordID: Self.sourceRecordID)
        }
        try store.verifySensorRetryDigest(Data("first".utf8), batchKey: Self.batchKey, sourceRecordID: Self.sourceRecordID)
        #expect(try Self.decodedJSON(try #require(store.encodedStateForTesting))["events"] == nil)
    }

    /// The state of another account generation is rewritten too: its events are as dead as the current account's.
    @Test
    func purgeAlsoDropsTheEventsOfAnotherAccountGeneration() throws {
        let store = FHIRExchangeStateStore(testingEncodedState: try Self.legacyState(accountDataGeneration: 3))

        try store.purgeLegacyExchangeEvents()

        let purged = try Self.decodedJSON(try #require(store.encodedStateForTesting))
        #expect(purged["events"] == nil)
        #expect(purged["accountDataGeneration"] as? Int == 3)
    }

    /// M9c: a purge that fails is retried at a later launch, and HealthKit exports meanwhile.
    @Test
    func failedPurgeIsRetriedAndLeavesTheLedgerUsable() throws {
        let unreadable = try FHIRExchangeStateStore(testingSchemaVersion: 2)
        FHIRExchangeStateStore.purgeLegacyExchangeEventsOnce(in: unreadable, preferences: preferences)

        #expect(!preferences[.didPurgeLegacyExchangeEvents])
        let delivery = try LedgerHarness(ledger: .forTesting()).deliver([LedgerHarness.steps(0)])
        #expect(delivery.events.count == 1)

        FHIRExchangeStateStore.purgeLegacyExchangeEventsOnce(in: FHIRExchangeStateStore(), preferences: preferences)
        #expect(preferences[.didPurgeLegacyExchangeEvents])
    }

    deinit {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }
}
