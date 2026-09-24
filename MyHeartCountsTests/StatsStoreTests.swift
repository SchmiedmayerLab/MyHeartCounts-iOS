//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import FirebaseCore
import FirebaseFirestore
import Foundation
@testable import MyHeartCounts
import Observation
import SpeziHealthKit
import SpeziHealthKitUI
import Synchronization
import Testing


@Suite(.timeLimit(.minutes(1)))
@MainActor
struct StatsStoreTests {
    @Test
    func repeatedUnavailableUpdatesDoNotInvalidateTheViewAgain() {
        let observation = StatsStore.Subscription<QuantitySample>()
        observation.fail(StatsStore.Error.unavailable, clear: true)
        let changed = Mutex(false)
        withObservationTracking {
            _ = observation.elements
            _ = observation.error
            _ = observation.isLoading
        } onChange: {
            changed.withLock { $0 = true }
        }
        observation.fail(StatsStore.Error.unavailable, clear: true)
        #expect(!changed.withLock { $0 })
    }

    @Test
    func oneShotReadsExposeCacheAndInvalidDocuments() async throws {
        try await withFirestore { firestore async throws in
            populate(firestore)
            firestore.document("users/first/stats/weight/months/2026-07").setData(["version": 42, "metric": "weight"], completion: nil)
            let store = StatsStore(firestore: firestore, accountID: { "first" })
            let result = try await store.fetch(request(), readPolicy: .cache)
            #expect(result.elements.map { $0.value(as: .gramUnit(with: .kilo)) } == [70])
            #expect(result.contributingSourceIDs == ["com.apple.HealthKit"])
            #expect(result.isFromCache)
            #expect(result.hasPendingWrites)
            #expect(result.diagnostics.contains(.invalidDocumentCount(1)))
        }
    }

    @Test
    func subscriptionsAreIndependentAndEndOnAccountInvalidation() async throws {
        try await withFirestore { firestore async throws in
            populate(firestore)
            let store = StatsStore(firestore: firestore, accountID: { "first" })
            var first = store.updates(for: request()).makeAsyncIterator()
            var second = store.updates(for: request()).makeAsyncIterator()
            #expect(try await first.next()?.elements.count == 1)
            #expect(try await second.next()?.elements.count == 1)
            store.invalidateSession()
            await #expect(throws: StatsStore.Error.self) { try await first.next(isolation: MainActor.shared) }
            await #expect(throws: StatsStore.Error.self) { try await second.next(isolation: MainActor.shared) }
            let refreshed = try await store.fetch(request(), readPolicy: .cache)
            #expect(refreshed.elements.count == 1)
        }
    }

    @Test
    func changingSourcePolicyReprocessesCachedDocuments() async throws {
        try await withFirestore { firestore async throws in
            populate(firestore)
            let store = StatsStore(firestore: firestore, accountID: { "first" })
            let observation = StatsStore.Subscription<QuantitySample>()
            let (stream, continuation) = AsyncThrowingStream<StatsStore.Snapshot<QuantitySample>, any Error>.makeStream()
            observation.onChange = { result in
                switch result {
                case .success(let snapshot): continuation.yield(snapshot)
                case .failure(let error): continuation.finish(throwing: error)
                }
            }
            var snapshots = stream.makeAsyncIterator()
            defer {
                observation.stop()
                continuation.finish()
            }
            observation.update(request: request(), store: store)
            #expect(try await snapshots.next()?.contributingSourceIDs == ["com.apple.HealthKit"])
            observation.update(request: request(sourcePolicy: .only("manual")), store: store)
            #expect(try await snapshots.next()?.elements.first?.value(as: .gramUnit(with: .kilo)) == 80)
            #expect(observation.snapshot?.contributingSourceIDs == ["manual"])
        }
    }

    @Test
    func logoutSuspendsReopeningQueriesForTheOldAccount() async throws {
        try await withFirestore { firestore async throws in
            populate(firestore)
            let store = StatsStore(firestore: firestore, accountID: { "first" })
            _ = try await store.fetch(request(), readPolicy: .cache)
            store.prepareForLogout()
            store.prepareForLogout()
            await #expect(throws: StatsStore.Error.self) { try await store.fetch(request(), readPolicy: .cache) }
            let observation = StatsStore.Subscription<QuantitySample>()
            observation.update(request: request(), store: store)
            #expect(observation.elements.isEmpty)
            #expect(observation.error is StatsStore.Error)
            #expect(!observation.isLoading)
        }
    }

    @Test
    func invalidationCancelsAnOutstandingServerFetch() async throws {
        try await withFirestore { firestore async throws in
            try await firestore.enableNetwork()
            let (started, continuation) = AsyncStream<Void>.makeStream()
            let store = StatsStore(firestore: firestore, accountID: {
                continuation.yield(())
                return "first"
            })
            var starts = started.makeAsyncIterator()
            let task = Task { try await store.fetch(request(), readPolicy: .server) }
            defer {
                task.cancel()
                continuation.finish()
            }
            _ = await starts.next()
            store.invalidateSession()
            await #expect(throws: StatsStore.Error.self) { try await task.value }
        }
    }

    @Test
    func requestIdentityIncludesEveryProcessingParameter() {
        let original = request()
        #expect(original == request())
        #expect(Set([original, request()]).count == 1)
        #expect(original != request(sourcePolicy: .only("manual")))
        let minimum: StatsStore.Request<QuantitySample> = .quantity(metric: .weight, timeRange: .ever, aggregationKind: .min)
        #expect(original != minimum)
        let narrowed: StatsStore.Request<QuantitySample> = .quantity(metric: .weight, timeRange: .last(days: 7), aggregationKind: .avg)
        #expect(original != narrowed)
    }

    private func request(sourcePolicy: StatsStore.SourcePolicy = .automatic) -> StatsStore.Request<QuantitySample> {
        .quantity(metric: .weight, timeRange: .ever, aggregationKind: .avg, sourcePolicy: sourcePolicy)
    }

    private func populate(_ firestore: Firestore) {
        firestore.document("users/first/stats/weight/months/2026-08").setData([
            "version": 0,
            "metric": "weight",
            "samples": [
                "com.apple.HealthKit": [["date": "2026-08-01T12:00:00Z", "value": 70, "unit": "kg"]],
                "manual": [["date": "2026-08-01T12:00:00Z", "value": 80, "unit": "kg"]]
            ]
        ])
    }

    private func withFirestore(_ operation: (Firestore) async throws -> Void) async throws {
        let name = "stats-store-\(UUID().uuidString)"
        let options = FirebaseOptions(googleAppID: "1:1234567890:ios:abcdef", gcmSenderID: "1234567890")
        options.projectID = "demo-stats-store"
        options.apiKey = "A" + String(repeating: "0", count: 38)
        FirebaseApp.configure(name: name, options: options)
        let app = try #require(FirebaseApp.app(name: name))
        let firestore = Firestore.firestore(app: app)
        let settings = FirestoreSettings()
        settings.cacheSettings = MemoryCacheSettings()
        settings.host = "127.0.0.1:9"
        settings.isSSLEnabled = false
        firestore.settings = settings
        do {
            try await firestore.disableNetwork()
            try await operation(firestore)
            try await firestore.terminate()
        } catch {
            try? await firestore.terminate()
            _ = await app.delete()
            throw error
        }
        #expect(await app.delete())
    }
}
