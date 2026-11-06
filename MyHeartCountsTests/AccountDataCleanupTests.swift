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
@testable import MyHeartCounts
import OSLog
import Testing


/// Account preferences of the test's own, set by the test.
private final class TestAccountPreferences: Sendable {
    private let suiteName = "edu.stanford.MyHeartCounts.unitTests.accountCleanup.\(UUID().uuidString)"
    let store: LocalPreferencesStore

    init() {
        // A suite name never equals the app's identifier, so `UserDefaults(suiteName:)` always returns one.
        store = LocalPreferencesStore(defaults: UserDefaults(suiteName: suiteName)!) // swiftlint:disable:this force_unwrapping
    }

    /// As `performLogoutCleanup` does: the cleanup is pending, under a generation of its own.
    func logOut(rotatingTo generation: Int) {
        store[.pendingAccountDataCleanupRequired] = true
        store[.accountDataGeneration] = generation
    }

    deinit {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }
}


/// The cleanup that ends an account's local data: every step runs, and it stays pending until all of them succeeded. A row
/// that records no subject is attributed to the drain's subject on the strength of this.
@Suite
struct AccountDataCleanupTests {
    private struct StepFailure: Error {}

    private let preferences = TestAccountPreferences()

    /// The account-data cleanup `clearPendingAccountData` runs, over this test's preferences.
    private func clearAccountData(_ steps: [MyHeartCountsStandard.AccountDataCleanupStep]) async throws {
        try await MyHeartCountsStandard.clearAccountData(
            steps,
            preferences: preferences.store,
            logger: Logger(subsystem: "edu.stanford.MyHeartCounts.unitTests", category: "AccountDataCleanupTests")
        )
    }

    /// The account fence, over this test's preferences.
    private func validateWrites(for generation: Int) throws {
        try FHIRExchangeDestination.validateWrites(
            for: generation,
            currentGeneration: preferences.store[.accountDataGeneration],
            cleanupPending: preferences.store[.pendingAccountDataCleanupRequired]
        )
    }

    /// While one step fails, the cleanup fails although every other step succeeded, cleanup stays pending, and the fence
    /// keeps refusing every write until a later cleanup succeeds.
    @Test
    func failingStepKeepsTheCleanupPending() async throws {
        var otherStepRan = false

        preferences.logOut(rotatingTo: 1)
        await #expect(throws: (any Error).self) {
            try await clearAccountData([
                .init("failing data") { throw StepFailure() },
                .init("other data") { otherStepRan = true }
            ])
        }
        #expect(otherStepRan)
        #expect(preferences.store[.pendingAccountDataCleanupRequired])
        #expect(throws: FHIRExchangeDestinationError.accountChanged) {
            try validateWrites(for: 1)
        }

        try await clearAccountData([.init("failing data") {}])
        #expect(!preferences.store[.pendingAccountDataCleanupRequired])
        try validateWrites(for: 1)
    }

    /// Any failing step keeps cleanup pending, and every step after it runs all the same: a row that records no subject and
    /// the batches' retry state are gone, so neither outlives the account.
    @Test
    func failingStepKeepsTheCleanupPendingAndStillClearsTheRest() async throws {
        let staging = try await HealthUploadStaging.resolvedForTesting()
        try await staging.add([ExchangeHarness.steps(0)])
        // As a build before v5 staged the row.
        try staging.writeForTesting { db in
            _ = try HealthUploadStaging.PendingSampleRecord.updateAll(
                db,
                HealthUploadStaging.PendingSampleRecord.Columns.subjectSystem.set(to: nil),
                HealthUploadStaging.PendingSampleRecord.Columns.subjectValue.set(to: nil)
            )
        }
        let retryState = FHIRExchangeStateStore(accountDataGeneration: 0)
        let earlierFacts = FHIRExchangeStateStore.SensorBatchFacts(
            timeZone: .gmt,
            conversionInstant: ExchangeHarness.start,
            conversionFacts: try .testing(),
            devices: .testing()
        )
        _ = try retryState.sensorBatchFacts("batch", current: earlierFacts)
        #expect(!(try staging.isEmpty))

        preferences.logOut(rotatingTo: 1)
        let nextRetryState = retryState.testingView(accountDataGeneration: 1)
        await #expect(throws: (any Error).self) {
            try await clearAccountData([
                .init("other data") { throw StepFailure() },
                .init("staged health observations") { try staging.clear() },
                .init("FHIR exchange identity and retry state") { try nextRetryState.reset() }
            ])
        }

        #expect(preferences.store[.pendingAccountDataCleanupRequired])
        #expect(try staging.isEmpty)
        let laterFacts = FHIRExchangeStateStore.SensorBatchFacts(
            timeZone: .gmt,
            conversionInstant: ExchangeHarness.start.addingTimeInterval(60),
            conversionFacts: try .testing(build: "101"),
            devices: .testing(device: UpdatedSensorKitDevice())
        )
        #expect(try nextRetryState.sensorBatchFacts("batch", current: laterFacts) == laterFacts)
    }
}
