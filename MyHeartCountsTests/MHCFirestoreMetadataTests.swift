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
import Testing


@Suite(.timeLimit(.minutes(1)))
@MainActor
struct MHCFirestoreMetadataTests {
    private struct Decoder: MyHeartCountsShared.ValueTransformer<QueryDocumentSnapshot, Int> {
        let probe: FirestoreProcessingProbe
        var multiplier = 1

        func transform(_ document: QueryDocumentSnapshot) throws -> Int {
            try probe.record()
            return try #require(document.data()["value"] as? Int) * multiplier
        }
    }

    /// Metadata-sensitive decoders retain their behavior; data-only decoders keep the same content revision.
    @Test(arguments: [false, true])
    func metadataReuseRequiresExplicitOptIn(ignoresMetadata: Bool) async throws {
        try await withQueryTestFirestore { firestore async throws in
            let documents = try await documents(in: firestore)
            let source = FirestoreQueryTestSource()
            let controller = MHCFirestoreQueryController<Int>(subscribe: source.subscribe)
            let probe = FirestoreProcessingProbe()
            var snapshots = snapshots(from: controller).makeAsyncIterator()
            defer { controller.stop() }
            controller.setup(
                firestore: firestore,
                query: MHCFirestoreQuerySpecification(collectionPath: "readings"),
                processing: MHCFirestoreQueryProcessing(decoder: Decoder(probe: probe), ignoresDocumentMetadata: ignoresMetadata)
            )
            source.send(input(documents, cached: true, changed: true))
            let initial = try #require(await snapshots.next())
            source.send(input(documents, cached: false, changed: false))
            let metadata = try #require(await snapshots.next())
            #expect(metadata.elements == initial.elements)
            #expect((metadata.contentRevision == initial.contentRevision) == ignoresMetadata)
            #expect(!metadata.isFromCache)
            #expect(!metadata.hasPendingWrites)
            #expect(probe.count == (ignoresMetadata ? 1 : 2))
        }
    }

    /// An initial empty snapshot must complete loading even though its document-change list is empty.
    @Test
    func initialEmptySnapshotIsDecodedBeforeMetadataCanBeReused() async throws {
        try await withQueryTestFirestore { firestore async throws in
            let source = FirestoreQueryTestSource()
            let controller = MHCFirestoreQueryController<Int>(subscribe: source.subscribe)
            var snapshots = snapshots(from: controller).makeAsyncIterator()
            defer { controller.stop() }
            controller.setup(
                firestore: firestore,
                query: MHCFirestoreQuerySpecification(collectionPath: "empty"),
                processing: MHCFirestoreQueryProcessing(decoder: Decoder(probe: FirestoreProcessingProbe()), ignoresDocumentMetadata: true)
            )
            #expect(controller.isLoading)
            source.send(input([], cached: true, changed: false))
            let initial = try #require(await snapshots.next())
            #expect(initial.elements.isEmpty)
            #expect(!controller.isLoading)
            source.send(input([], cached: false, changed: false))
            let metadata = try #require(await snapshots.next())
            #expect(metadata.contentRevision == initial.contentRevision)
            #expect(!metadata.isFromCache)
        }
    }

    /// Metadata is overlaid onto a decode already in progress instead of starting another decode.
    @Test
    func metadataDuringDecodeIsPublishedWithTheOriginalResult() async throws {
        try await withQueryTestFirestore { firestore async throws in
            let documents = try await documents(in: firestore)
            let source = FirestoreQueryTestSource()
            let controller = MHCFirestoreQueryController<Int>(subscribe: source.subscribe)
            let probe = FirestoreProcessingProbe()
            var snapshots = snapshots(from: controller).makeAsyncIterator()
            defer { controller.stop() }
            var wasLoadingDuringDecode = false
            var hadSnapshotDuringDecode = true
            probe.duringNextCall {
                source.send(input(documents, cached: false, changed: false))
                wasLoadingDuringDecode = controller.isLoading
                hadSnapshotDuringDecode = controller.snapshot != nil
            }
            controller.setup(
                firestore: firestore,
                query: MHCFirestoreQuerySpecification(collectionPath: "readings"),
                processing: MHCFirestoreQueryProcessing(decoder: Decoder(probe: probe), ignoresDocumentMetadata: true)
            )
            source.send(input(documents, cached: true, changed: true))
            let result = try #require(await snapshots.next())
            #expect(wasLoadingDuringDecode)
            #expect(!hadSnapshotDuringDecode)
            #expect(result.elements == [7])
            #expect(!result.isFromCache)
            #expect(!result.hasPendingWrites)
            #expect(probe.count == 1)
        }
    }

    /// A decoder change supersedes in-flight work even when the latest input only changes metadata.
    @Test
    func metadataDuringDecodeDoesNotReviveSupersededProcessing() async throws {
        try await withQueryTestFirestore { firestore async throws in
            let documents = try await documents(in: firestore)
            let source = FirestoreQueryTestSource()
            let controller = MHCFirestoreQueryController<Int>(subscribe: source.subscribe)
            let original = FirestoreProcessingProbe()
            let replacement = FirestoreProcessingProbe()
            var snapshots = snapshots(from: controller).makeAsyncIterator()
            defer { controller.stop() }
            let query = MHCFirestoreQuerySpecification(collectionPath: "readings")
            original.duringNextCall {
                source.send(input(documents, cached: false, changed: false))
                controller.setup(
                    firestore: firestore,
                    query: query,
                    processing: MHCFirestoreQueryProcessing(decoder: Decoder(probe: replacement, multiplier: 10), ignoresDocumentMetadata: true)
                )
            }
            controller.setup(
                firestore: firestore,
                query: query,
                processing: MHCFirestoreQueryProcessing(decoder: Decoder(probe: original), ignoresDocumentMetadata: true)
            )
            source.send(input(documents, cached: true, changed: true))
            let result = try #require(await snapshots.next())
            #expect(result.elements == [70])
            #expect(!result.isFromCache)
            #expect(original.count == 1)
            #expect(replacement.count == 1)
        }
    }

    private func documents(in firestore: Firestore) async throws -> [QueryDocumentSnapshot] {
        firestore.document("readings/first").setData(["value": 7], completion: nil)
        return try await firestore.collection("readings").getDocuments(source: .cache).documents
    }

    private func input(_ documents: [QueryDocumentSnapshot], cached: Bool, changed: Bool) -> MHCFirestoreQueryInput {
        MHCFirestoreQueryInput(documents: documents, isFromCache: cached, hasPendingWrites: cached, hasDocumentChanges: changed)
    }

    private func snapshots(from controller: MHCFirestoreQueryController<Int>) -> AsyncThrowingStream<MHCFirestoreSnapshot<Int>, any Error> {
        let (stream, continuation) = AsyncThrowingStream<MHCFirestoreSnapshot<Int>, any Error>.makeStream()
        controller.onChange = { result in
            switch result {
            case .success(let snapshot): continuation.yield(snapshot)
            case .failure(let error): continuation.finish(throwing: error)
            }
        }
        return stream
    }
}
