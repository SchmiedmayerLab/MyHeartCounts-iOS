//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import FirebaseFirestore
import Foundation
@testable import MyHeartCounts
import MyHeartCountsShared
import SpeziHealthKit
import SpeziHealthKitUI
import Testing


@Suite(.timeLimit(.minutes(1)))
@MainActor
struct StatsObservationMetadataTests {
    private struct Processor: MyHeartCountsShared.ValueTransformer<[StatsDocument], StatsStore.Processor.Output<QuantitySample>> {
        let probe: FirestoreProcessingProbe
        let request: StatsStore.Request<QuantitySample>

        func transform(_ documents: [StatsDocument]) throws -> StatsStore.Processor.Output<QuantitySample> {
            try probe.record()
            return try request.process(documents)
        }
    }

    @MainActor
    private struct Fixture {
        let source = FirestoreQueryTestSource()
        let controller: MHCFirestoreQueryController<StatsDocument>
        let observation: StatsStore.Subscription<QuantitySample>
        let store: StatsStore
        let documents: [QueryDocumentSnapshot]

        init(firestore: Firestore) async throws {
            controller = MHCFirestoreQueryController(subscribe: source.subscribe)
            observation = StatsStore.Subscription(controller: controller)
            store = StatsStore(firestore: firestore, accountID: { "first" })
            let months = firestore.collection("users/first/stats/weight/months")
            months.document("2026-08").setData([
                "version": 0, "metric": "weight",
                "samples": [
                    "com.apple.HealthKit": [["date": "2026-08-01T12:00:00Z", "value": 70, "unit": "kg"]],
                    "manual": [["date": "2026-08-01T12:00:00Z", "value": 80, "unit": "kg"]]
                ]
            ], completion: nil)
            documents = try await months.getDocuments(source: .cache).documents
        }

        func send(cached: Bool, changed: Bool) {
            source.send(MHCFirestoreQueryInput(
                documents: documents, isFromCache: cached, hasPendingWrites: cached, hasDocumentChanges: changed
            ))
        }
    }

    /// Changing freshness metadata preserves both processing results and generated sample identity.
    @Test
    func metadataPreservesSamplesDiagnosticsAndSources() async throws {
        try await withQueryTestFirestore { firestore async throws in
            let fixture = try await Fixture(firestore: firestore)
            let probe = FirestoreProcessingProbe()
            var snapshots = snapshots(from: fixture.observation).makeAsyncIterator()
            defer { fixture.observation.stop() }
            fixture.observation.update(request: request(probe), store: fixture.store)
            fixture.send(cached: true, changed: true)
            let initial = try #require(await snapshots.next())
            let revision = fixture.controller.snapshot?.contentRevision
            fixture.send(cached: false, changed: false)
            let metadata = try #require(await snapshots.next())
            #expect(metadata.elements.map(\.id) == initial.elements.map(\.id))
            #expect(metadata.diagnostics == initial.diagnostics)
            #expect(metadata.contributingSourceIDs == initial.contributingSourceIDs)
            #expect(!metadata.isFromCache)
            #expect(!metadata.hasPendingWrites)
            #expect(fixture.controller.snapshot?.contentRevision == revision)
            #expect(probe.count == 1)
        }
    }

    /// Metadata during initial processing neither starts duplicate work nor ends loading prematurely.
    @Test
    func metadataDuringInitialProcessingUsesTheLatestFlags() async throws {
        try await withQueryTestFirestore { firestore async throws in
            let fixture = try await Fixture(firestore: firestore)
            let probe = FirestoreProcessingProbe()
            var snapshots = snapshots(from: fixture.observation).makeAsyncIterator()
            defer { fixture.observation.stop() }
            var observedLoading = false
            var observedUpdating = true
            probe.duringNextCall {
                fixture.send(cached: false, changed: false)
                observedLoading = fixture.observation.isLoading
                observedUpdating = fixture.observation.isUpdating
            }
            fixture.observation.update(request: request(probe), store: fixture.store)
            fixture.send(cached: true, changed: true)
            #expect(try await snapshots.next()?.isFromCache == false)
            #expect(observedLoading)
            #expect(!observedUpdating)
            #expect(probe.count == 1)
            #expect(!fixture.observation.isLoading)
        }
    }

    /// A refresh retains its usable result and reports updating while processing new data.
    @Test
    func refreshingRetainedDataDoesNotBecomeInitialLoading() async throws {
        try await withQueryTestFirestore { firestore async throws in
            let fixture = try await Fixture(firestore: firestore)
            let probe = FirestoreProcessingProbe()
            var snapshots = snapshots(from: fixture.observation).makeAsyncIterator()
            defer { fixture.observation.stop() }
            fixture.observation.update(request: request(probe), store: fixture.store)
            fixture.send(cached: true, changed: true)
            let initial = try #require(await snapshots.next())
            var observedLoading = true
            var observedUpdating = false
            var retainedIDs: [UUID] = []
            probe.duringNextCall {
                observedLoading = fixture.observation.isLoading
                observedUpdating = fixture.observation.isUpdating
                retainedIDs = fixture.observation.elements.map(\.id)
                fixture.send(cached: false, changed: false)
            }
            fixture.send(cached: true, changed: true)
            // The raw decoder has been scheduled but cannot run on this actor until the next suspension.
            #expect(fixture.controller.isUpdating)
            #expect(fixture.observation.isUpdating)
            let refreshed = try #require(await snapshots.next())
            #expect(!observedLoading)
            #expect(observedUpdating)
            #expect(retainedIDs == initial.elements.map(\.id))
            #expect(probe.count == 2)
            #expect(!refreshed.isFromCache)
            #expect(!fixture.observation.isUpdating)
        }
    }

    /// A request change must run its new processor even if the retained documents only received metadata changes.
    @Test
    func requestChangesSupersedeProcessingAndKeepRetainedLoadingState() async throws {
        try await withQueryTestFirestore { firestore async throws in
            let fixture = try await Fixture(firestore: firestore)
            let original = FirestoreProcessingProbe()
            let replacement = FirestoreProcessingProbe()
            var snapshots = snapshots(from: fixture.observation).makeAsyncIterator()
            defer { fixture.observation.stop() }
            fixture.observation.update(request: request(original), store: fixture.store)
            fixture.send(cached: true, changed: true)
            _ = try await snapshots.next()
            var observedLoading = true
            var observedUpdating = false
            replacement.duringNextCall {
                observedLoading = fixture.observation.isLoading
                observedUpdating = fixture.observation.isUpdating
                fixture.send(cached: false, changed: false)
            }
            fixture.observation.update(request: request(replacement, source: .only("manual")), store: fixture.store)
            let changed = try #require(await snapshots.next())
            #expect(!observedLoading)
            #expect(observedUpdating)
            #expect(replacement.count == 1)
            #expect(changed.elements.first?.value(as: .gramUnit(with: .kilo)) == 80)
            #expect(changed.contributingSourceIDs == ["manual"])
            #expect(!changed.isFromCache)
            #expect(original.count == 1)
        }
    }

    /// Cancelling the account discards processing and metadata from its removed listener.
    @Test
    func accountInvalidationClearsPendingProcessingAndMetadata() async throws {
        try await withQueryTestFirestore { firestore async throws in
            let fixture = try await Fixture(firestore: firestore)
            let probe = FirestoreProcessingProbe()
            var snapshots = snapshots(from: fixture.observation).makeAsyncIterator()
            defer { fixture.observation.stop() }
            probe.duringNextCall {
                fixture.store.invalidateSession()
                fixture.send(cached: false, changed: false)
            }
            fixture.observation.update(request: request(probe), store: fixture.store)
            fixture.send(cached: true, changed: true)
            await #expect(throws: StatsStore.Error.self) { try await snapshots.next(isolation: MainActor.shared) }
            #expect(probe.count == 1)
            #expect(fixture.observation.elements.isEmpty)
            #expect(fixture.observation.error as? StatsStore.Error == .sessionChanged)
            #expect(!fixture.observation.isLoading)
            #expect(!fixture.observation.isUpdating)
        }
    }

    private func request(_ probe: FirestoreProcessingProbe, source: StatsStore.SourcePolicy = .automatic) -> StatsStore.Request<QuantitySample> {
        let base: StatsStore.Request<QuantitySample> = .quantity(metric: .weight, timeRange: .ever, aggregationKind: .avg, sourcePolicy: source)
        return StatsStore.Request(metricId: .weight, timeRange: base.timeRange, processor: Processor(probe: probe, request: base))
    }

    private func snapshots(
        from observation: StatsStore.Subscription<QuantitySample>
    ) -> AsyncThrowingStream<StatsStore.Snapshot<QuantitySample>, any Error> {
        let (stream, continuation) = AsyncThrowingStream<StatsStore.Snapshot<QuantitySample>, any Error>.makeStream()
        observation.onChange = { result in
            switch result {
            case .success(let snapshot): continuation.yield(snapshot)
            case .failure(let error): continuation.finish(throwing: error)
            }
        }
        return stream
    }
}
