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
@testable import MyHeartCounts
import Testing


/// M9: HealthKit's reservations leave the encrypted state once, best effort, and the ledger never depends on it.
@Suite
final class FHIRExchangeLegacyPurgeTests {
    private let suiteName = "edu.stanford.MyHeartCounts.unitTests.legacyPurge.\(UUID().uuidString)"
    private let preferences: LocalPreferencesStore

    init() throws {
        preferences = LocalPreferencesStore(defaults: try #require(UserDefaults(suiteName: suiteName)))
    }

    private static func reserve(_ key: String, in store: FHIRExchangeStateStore) throws -> PersistedFHIRExchangeEvent {
        try store.event(key: key, recordedAt: LedgerHarness.start, facts: .current())
    }

    /// M9a: an installation without encrypted state gets none, and HealthKit starts on an empty ledger.
    @Test
    func withoutLegacyStateTheLedgerStartsEmpty() throws {
        let store = FHIRExchangeStateStore()
        FHIRExchangeStateStore.purgeLegacyHealthKitEventsOnce(in: store, preferences: preferences)

        #expect(preferences[.didPurgeLegacyHealthKitExchangeEvents])
        #expect(try !store.hasPersistedStateForTesting)
        let ledger = FHIRExchangeLedger.forTesting()
        #expect(try ledger.entriesForTesting().isEmpty)
        let delivery = try LedgerHarness(identity: store, ledger: ledger).deliver([LedgerHarness.steps(0)])
        #expect(delivery.events.values.map(\.sequence.rawValue) == ["1"])
    }

    /// M9b: only HealthKit's reservations go; SensorKit's and the questionnaires' stay with the instance and its
    /// counter, and a later launch does not purge again.
    @Test
    func purgeKeepsEverythingButHealthKitAndRunsOnce() throws {
        let store = FHIRExchangeStateStore()
        let sensorKit = try Self.reserve("sensorkit|batch|record", in: store)
        let questionnaire = try Self.reserve("questionnaire|participant|response", in: store)
        _ = try Self.reserve("healthkit|participant|HKQuantityTypeIdentifierStepCount|uuid", in: store)
        let last = try Self.reserve("healthkit-retraction|participant|HKQuantityTypeIdentifierStepCount|uuid", in: store)
        let instance = try store.producerInstance()

        FHIRExchangeStateStore.purgeLegacyHealthKitEventsOnce(in: store, preferences: preferences)

        #expect(try store.eventKeysForTesting == ["sensorkit|batch|record", "questionnaire|participant|response"])
        #expect(try store.producerInstance() == instance)
        #expect(try Self.reserve("sensorkit|batch|record", in: store) == sensorKit)
        #expect(try Self.reserve("questionnaire|participant|response", in: store) == questionnaire)
        #expect(try Self.reserve("sensorkit|batch|next", in: store).sequence == last.sequence + 1)
        #expect(preferences[.didPurgeLegacyHealthKitExchangeEvents])

        _ = try Self.reserve("healthkit|participant|late", in: store)
        FHIRExchangeStateStore.purgeLegacyHealthKitEventsOnce(in: store, preferences: preferences)
        #expect(try store.eventKeysForTesting.contains("healthkit|participant|late"))
    }

    /// M9c: a purge that fails is retried at a later launch, and HealthKit exports meanwhile.
    @Test
    func failedPurgeIsRetriedAndLeavesTheLedgerUsable() throws {
        let unreadable = FHIRExchangeStateStore(testingSchemaVersion: 1)
        FHIRExchangeStateStore.purgeLegacyHealthKitEventsOnce(in: unreadable, preferences: preferences)

        #expect(!preferences[.didPurgeLegacyHealthKitExchangeEvents])
        let delivery = try LedgerHarness(ledger: .forTesting()).deliver([LedgerHarness.steps(0)])
        #expect(delivery.events.count == 1)

        FHIRExchangeStateStore.purgeLegacyHealthKitEventsOnce(in: FHIRExchangeStateStore(), preferences: preferences)
        #expect(preferences[.didPurgeLegacyHealthKitExchangeEvents])
    }

    deinit {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }
}
