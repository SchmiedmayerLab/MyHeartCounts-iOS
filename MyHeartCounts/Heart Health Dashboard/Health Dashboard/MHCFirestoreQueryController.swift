//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import FirebaseFirestore
import Foundation
import MyHeartCountsShared
import Observation
import OSLog


/// Owns a Firestore subscription without depending on SwiftUI or an account environment.
///
/// Each controller owns its listener. Call `stop()` when its account session ends;
/// callers resolve account-specific collection paths before supplying a specification.
@Observable
@MainActor
final class MHCFirestoreQueryController<Element: Sendable> {
    typealias Subscription = @MainActor (
        Query, @escaping @MainActor @Sendable (Result<MHCFirestoreQueryInput, any Error>) -> Void
    ) -> any ListenerRegistration

    private struct MissingSnapshot: Error {}

    @ObservationIgnored private let subscribe: Subscription
    @ObservationIgnored private var listener: (any ListenerRegistration)?
    @ObservationIgnored private var activeFirestore: Firestore?
    @ObservationIgnored private var activeQuery: MHCFirestoreQuerySpecification?
    @ObservationIgnored private var processing: MHCFirestoreQueryProcessing<Element>?
    /// Rejects callbacks from a removed listener, including ones already queued on the main actor.
    @ObservationIgnored private var listenerGeneration = 0
    @ObservationIgnored private var lastSnapshot: MHCFirestoreQueryInput?
    /// Rejects old decodes and scheduled reprocessing after new input, replacement, or stop.
    @ObservationIgnored private var snapshotGeneration = 0
    @ObservationIgnored private var decodedGeneration: Int?
    @ObservationIgnored private var decodingTask: Task<Void, Never>?
    @ObservationIgnored private let logger = Logger(category: .init("MHCFirestoreQueryController<\(Element.self)>"))

    /// Called after a new snapshot is decoded, or when the listener reports an error.
    @ObservationIgnored var onChange: (@MainActor (Result<MHCFirestoreSnapshot<Element>, any Error>) -> Void)?
    private(set) var snapshot: MHCFirestoreSnapshot<Element>?
    private(set) var error: (any Error)?
    /// Waiting for the first decoded snapshot of the current query.
    private(set) var isLoading = false
    /// Decoding changed contents or interpretation while retaining the previous result.
    private(set) var isUpdating = false

    var elements: [Element] {
        snapshot?.elements ?? []
    }

    /// Metadata delivery is fixed for the lifetime of the controller, independently of decoder behavior.
    nonisolated init(includeMetadataChanges: Bool = true) {
        subscribe = { query, receive in
            query.addSnapshotListener(includeMetadataChanges: includeMetadataChanges) { @Sendable snapshot, error in
                Task { @MainActor in
                    if let snapshot {
                        receive(.success(MHCFirestoreQueryInput(snapshot)))
                    } else if let error {
                        receive(.failure(error))
                    }
                }
            }
        }
    }

    init(subscribe: @escaping Subscription) {
        self.subscribe = subscribe
    }

    /// Performs a real one-shot read with explicit Firestore cache/server behavior.
    ///
    /// Cancelling stops our wait promptly; Firestore may still finish its underlying read.
    nonisolated static func fetch(
        firestore: Firestore,
        query: MHCFirestoreQuerySpecification,
        processing: MHCFirestoreQueryProcessing<Element>,
        source: FirestoreSource = .default
    ) async throws -> MHCFirestoreSnapshot<Element> {
        try Task.checkCancellation()
        let (snapshots, continuation) = AsyncThrowingStream<QuerySnapshot, any Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
        // Use the completion-handler overload so AsyncThrowingStream can end our wait promptly
        // when the task is cancelled. The imported async overload waits for Firestore's callback
        // even after cancellation; neither approach cancels the underlying Firestore request.
        query.query(in: firestore).getDocuments(source: source) { snapshot, error in
            if let error {
                continuation.finish(throwing: error)
            } else if let snapshot {
                continuation.yield(snapshot)
                continuation.finish()
            } else {
                continuation.finish(throwing: MissingSnapshot())
            }
        }
        for try await snapshot in snapshots {
            try Task.checkCancellation()
            let decoded = await processing.decode(MHCFirestoreQueryInput(snapshot))
            try Task.checkCancellation()
            return decoded
        }
        try Task.checkCancellation()
        throw MissingSnapshot()
    }

    /// Reuses the listener for processing-only changes and decodes the retained snapshot again.
    func setup(
        firestore: Firestore,
        query: MHCFirestoreQuerySpecification,
        processing: MHCFirestoreQueryProcessing<Element>
    ) {
        let oldProcessing = self.processing
        self.processing = processing
        guard activeFirestore === firestore, activeQuery == query else {
            replaceListener(firestore: firestore, query: query)
            return
        }
        guard oldProcessing != processing else {
            return
        }
        decodeRetainedSnapshot()
    }

    /// Removes the listener and clears all account-bound state and pending processing.
    func stop() {
        listener?.remove()
        listener = nil
        activeFirestore = nil
        activeQuery = nil
        lastSnapshot = nil
        processing = nil
        listenerGeneration += 1
        snapshotGeneration += 1
        decodedGeneration = nil
        decodingTask?.cancel()
        decodingTask = nil
        // SwiftUI calls stop repeatedly while there is no account. Optional snapshots
        // are not Equatable, so assigning nil again would invalidate observing views.
        if snapshot != nil {
            snapshot = nil
        }
        if error != nil {
            error = nil
        }
        if isLoading {
            isLoading = false
        }
        isUpdating = false
    }

    private func replaceListener(firestore: Firestore, query: MHCFirestoreQuerySpecification) {
        listener?.remove()
        listener = nil
        activeFirestore = firestore
        activeQuery = query
        listenerGeneration += 1
        let listenerGeneration = listenerGeneration
        lastSnapshot = nil
        snapshotGeneration += 1
        decodedGeneration = nil
        decodingTask?.cancel()
        decodingTask = nil
        snapshot = nil
        error = nil
        isLoading = true
        isUpdating = false
        listener = subscribe(query.query(in: firestore)) { [weak self] result in
            guard let self else {
                return
            }
            switch result {
            case .success(let snapshot):
                self.receive(snapshot, from: listenerGeneration)
            case .failure(let error):
                self.process(error, from: listenerGeneration)
            }
        }
    }

    private func receive(_ input: MHCFirestoreQueryInput, from listenerGeneration: Int) {
        guard listenerGeneration == self.listenerGeneration, let processing else {
            return
        }
        let onlyMetadataChanged = processing.ignoresDocumentMetadata && !input.hasDocumentChanges && lastSnapshot != nil
        lastSnapshot = input
        if onlyMetadataChanged {
            if decodedGeneration == snapshotGeneration, let snapshot {
                publish(snapshot.updatingMetadata(from: input))
            }
            // An in-flight decode picks up the latest metadata when it completes.
            return
        }
        decodeRetainedSnapshot()
    }

    private func decodeRetainedSnapshot() {
        guard let lastSnapshot, let processing else {
            return
        }
        snapshotGeneration += 1
        let generation = snapshotGeneration
        decodingTask?.cancel()
        isLoading = snapshot == nil
        isUpdating = snapshot != nil
        decodingTask = Task { [weak self] in
            guard !Task.isCancelled else {
                return
            }
            let decoded = await processing.decode(lastSnapshot)
            guard let self, !Task.isCancelled, generation == self.snapshotGeneration, let latest = self.lastSnapshot else {
                return
            }
            self.decodingTask = nil
            self.decodedGeneration = generation
            self.publish(decoded.updatingMetadata(from: latest))
        }
    }

    private func publish(_ snapshot: MHCFirestoreSnapshot<Element>) {
        self.snapshot = snapshot
        error = nil
        isLoading = false
        isUpdating = false
        onChange?(.success(snapshot))
    }

    private func process(_ error: any Error, from listenerGeneration: Int) {
        guard listenerGeneration == self.listenerGeneration else {
            return
        }
        snapshotGeneration += 1
        decodingTask?.cancel()
        decodingTask = nil
        self.error = error
        isLoading = false
        isUpdating = false
        logger.error("encountered error in firebase snapshot listener: \(error)")
        onChange?(.failure(error))
    }

    isolated deinit {
        decodingTask?.cancel()
        listener?.remove()
    }
}
