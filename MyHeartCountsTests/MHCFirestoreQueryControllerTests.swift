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
import MyHeartCountsShared
import Observation
import Synchronization
import Testing


@Suite(.timeLimit(.minutes(1)))
@MainActor
struct MHCFirestoreQueryControllerTests {
    private struct DocumentDecoder: MyHeartCountsShared.ValueTransformer<QueryDocumentSnapshot, QueryDocumentSnapshot> {
        func transform(_ input: QueryDocumentSnapshot) -> QueryDocumentSnapshot {
            input
        }
    }

    private struct IntegerDecoder: MyHeartCountsShared.ValueTransformer<QueryDocumentSnapshot, Int> {
        struct InvalidValue: Error {}

        var multiplier = 1

        func transform(_ input: QueryDocumentSnapshot) throws -> Int {
            guard let value = input.data()["value"] as? Int else {
                throw InvalidValue()
            }
            return value * multiplier
        }
    }

    /// A one-shot cache read works without an account environment or any active subscription.
    @Test
    func cacheFetchPreservesDocumentsAndMetadata() async throws {
        try await withOfflineFirestore { firestore async throws in
            firestore.document("readings/first").setData(["value": 7], completion: nil)
            let snapshot = try await MHCFirestoreQueryController<QueryDocumentSnapshot>.fetch(
                firestore: firestore,
                query: MHCFirestoreQuerySpecification(collectionPath: "readings"),
                processing: MHCFirestoreQueryProcessing(decoder: DocumentDecoder()),
                source: .cache
            )
            #expect(snapshot.elements.map(\.documentID) == ["first"])
            #expect(snapshot.elements.first?.data()["value"] as? Int == 7)
            #expect(snapshot.isFromCache)
            #expect(snapshot.hasPendingWrites)
            #expect(snapshot.failedDocumentCount == 0)
        }
    }

    /// Malformed documents produce a partial result; transport failures still throw.
    @Test
    func decodingFailuresRemainDistinctFromReadErrors() async throws {
        try await withOfflineFirestore { firestore async throws in
            firestore.document("readings/valid").setData(["value": 7], completion: nil)
            firestore.document("readings/invalid").setData(["value": "invalid"], completion: nil)
            let query = MHCFirestoreQuerySpecification(collectionPath: "readings")
            let processing = MHCFirestoreQueryProcessing(decoder: IntegerDecoder())
            let snapshot = try await MHCFirestoreQueryController<Int>.fetch(
                firestore: firestore, query: query, processing: processing, source: .cache
            )
            #expect(snapshot.elements == [7])
            #expect(snapshot.failedDocumentCount == 1)
            await #expect(throws: (any Error).self) {
                try await MHCFirestoreQueryController<Int>.fetch(
                    firestore: firestore, query: query, processing: processing, source: .server
                )
            }
        }
    }

    /// Changing only interpretation reuses cached documents, including sort and limit changes.
    @Test
    func processingChangesReplayTheRetainedSnapshot() async throws {
        try await withOfflineFirestore { firestore async throws in
            firestore.document("readings/first").setData(["value": 2], completion: nil)
            firestore.document("readings/second").setData(["value": 4], completion: nil)
            let controller = MHCFirestoreQueryController<Int>()
            var snapshots = snapshots(from: controller).makeAsyncIterator()
            defer { controller.stop() }
            let query = MHCFirestoreQuerySpecification(collectionPath: "readings")
            controller.setup(firestore: firestore, query: query, processing: MHCFirestoreQueryProcessing(decoder: IntegerDecoder()))
            #expect(try await snapshots.next()?.elements == [2, 4])

            controller.setup(
                firestore: firestore,
                query: query,
                processing: MHCFirestoreQueryProcessing(
                    decoder: IntegerDecoder(multiplier: 10), sort: [KeyPathComparator(\Int.self, order: .reverse)], limit: 1
                )
            )
            let replay = try #require(await snapshots.next())
            #expect(replay.elements == [20])
            #expect(replay.isFromCache)
            #expect(replay.hasPendingWrites)
            #expect(controller.error == nil)
            #expect(!controller.isLoading)
            controller.stop()
            #expect(controller.snapshot == nil)
            #expect(controller.elements.isEmpty)
        }
    }

    /// A queued replay of the previous account's documents cannot populate a replacement query.
    @Test
    func queryReplacementInvalidatesScheduledReprocessing() async throws {
        try await withOfflineFirestore { firestore async throws in
            firestore.document("firstAccount/value").setData(["value": 1], completion: nil)
            firestore.document("secondAccount/value").setData(["value": 2], completion: nil)
            let controller = MHCFirestoreQueryController<Int>()
            var snapshots = snapshots(from: controller).makeAsyncIterator()
            defer { controller.stop() }
            let firstQuery = MHCFirestoreQuerySpecification(collectionPath: "firstAccount")
            controller.setup(firestore: firestore, query: firstQuery, processing: MHCFirestoreQueryProcessing(decoder: IntegerDecoder()))
            #expect(try await snapshots.next()?.elements == [1])

            controller.setup(
                firestore: firestore, query: firstQuery, processing: MHCFirestoreQueryProcessing(decoder: IntegerDecoder(multiplier: 10))
            )
            controller.setup(
                firestore: firestore,
                query: MHCFirestoreQuerySpecification(collectionPath: "secondAccount"),
                processing: MHCFirestoreQueryProcessing(decoder: IntegerDecoder())
            )
            #expect(controller.elements.isEmpty)
            #expect(controller.isLoading)
            #expect(try await snapshots.next()?.elements == [2])
            #expect(controller.elements == [2])
        }
    }

    /// A pending server request must not hold a cancelled background calculation open.
    @Test
    func cancellationEndsAnOutstandingServerRead() async throws {
        try await withOfflineFirestore { firestore async throws in
            try await firestore.enableNetwork()
            let (started, continuation) = AsyncStream<Void>.makeStream()
            var starts = started.makeAsyncIterator()
            let read = Task {
                continuation.yield(())
                return try await MHCFirestoreQueryController<Int>.fetch(
                    firestore: firestore,
                    query: MHCFirestoreQuerySpecification(collectionPath: "uncached"),
                    processing: MHCFirestoreQueryProcessing(decoder: IntegerDecoder()),
                    source: .server
                )
            }
            defer {
                read.cancel()
                continuation.finish()
            }
            _ = await starts.next()
            read.cancel()
            await #expect(throws: CancellationError.self) { try await read.value }
        }
    }

    /// Repeated SwiftUI updates without an account must not create their own invalidation loop.
    @Test
    func stoppingInactiveControllerDoesNotInvalidateObservation() {
        let controller = MHCFirestoreQueryController<Int>()
        let changed = Mutex(false)
        withObservationTracking {
            _ = controller.elements
            _ = controller.error
            _ = controller.isLoading
        } onChange: {
            changed.withLock { $0 = true }
        }
        controller.stop()
        controller.stop()
        #expect(!changed.withLock { $0 })
    }

    private func snapshots(
        from controller: MHCFirestoreQueryController<Int>
    ) -> AsyncThrowingStream<MHCFirestoreSnapshot<Int>, any Error> {
        let (stream, continuation) = AsyncThrowingStream<MHCFirestoreSnapshot<Int>, any Error>.makeStream()
        controller.onChange = { result in
            switch result {
            case .success(let snapshot):
                continuation.yield(snapshot)
            case .failure(let error):
                continuation.finish(throwing: error)
            }
        }
        return stream
    }

    private func withOfflineFirestore(_ operation: (Firestore) async throws -> Void) async throws {
        let name = "firestore-query-offline-\(UUID().uuidString)"
        let options = FirebaseOptions(googleAppID: "1:1234567890:ios:abcdef", gcmSenderID: "1234567890")
        options.projectID = "demo-firestore-query-offline"
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
