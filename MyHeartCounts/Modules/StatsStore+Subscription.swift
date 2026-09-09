//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import Observation


extension StatsStore {
    /// Owns one stats subscription and reprocesses retained documents when only the request's interpretation changes.
    @Observable
    @MainActor
    final class Subscription<Element: Sendable> {
        private struct ProcessingIdentity: Equatable {
            let contentRevision: UUID
            let request: Request<Element>
        }

        @ObservationIgnored private let controller: MHCFirestoreQueryController<StatsDocument>
        @ObservationIgnored private var store: StatsStore?
        @ObservationIgnored private var session: Session?
        @ObservationIgnored private var request: Request<Element>?
        @ObservationIgnored private var cancellationID: UUID?
        @ObservationIgnored private var generation = 0
        @ObservationIgnored private var processingTask: Task<Void, Never>?
        @ObservationIgnored private var processingIdentity: ProcessingIdentity?
        @ObservationIgnored private var processedIdentity: ProcessingIdentity?
        @ObservationIgnored private var latestDocuments: MHCFirestoreSnapshot<StatsDocument>?
        @ObservationIgnored var onChange: (@MainActor (Result<Snapshot<Element>, any Swift.Error>) -> Void)?

        private(set) var snapshot: Snapshot<Element>?
        private(set) var error: (any Swift.Error)?
        /// Waiting for an initial result, including an empty result, for the current query.
        private(set) var isLoading = false
        private var isProcessing = false

        /// Decoding or processing changes while retaining a usable snapshot.
        var isUpdating: Bool { isProcessing || (snapshot != nil && controller.isUpdating) }

        var elements: [Element] { snapshot?.elements ?? [] }

        init(controller: MHCFirestoreQueryController<StatsDocument> = .init()) {
            self.controller = controller
        }

        func update(request: Request<Element>, store: StatsStore) {
            do {
                let (firestore, session) = try store.context()
                guard self.store !== store || self.session != session || self.request != request else {
                    return
                }
                let queryChanged = self.request.map {
                    StatsStore.query(for: $0, accountID: session.accountID) != StatsStore.query(for: request, accountID: session.accountID)
                } ?? true
                if self.store !== store || self.session != session {
                    stop()
                    self.store = store
                    self.session = session
                    cancellationID = store.registerCancellation { [weak self] in
                        self?.fail(Error.sessionChanged, clear: true)
                    }
                }
                generation += 1
                processingTask?.cancel()
                processingTask = nil
                processingIdentity = nil
                self.request = request
                error = nil
                if queryChanged {
                    snapshot = nil
                    processedIdentity = nil
                    latestDocuments = nil
                }
                isLoading = snapshot == nil
                isProcessing = snapshot != nil
                controller.onChange = { [weak self] result in self?.receive(result) }
                controller.setup(
                    firestore: firestore,
                    query: StatsStore.query(for: request, accountID: session.accountID),
                    processing: StatsStore.processing(for: request)
                )
                if let retained = controller.snapshot {
                    receive(.success(retained))
                }
            } catch {
                fail(error, clear: true)
            }
        }

        func stop() {
            generation += 1
            processingTask?.cancel()
            processingTask = nil
            processingIdentity = nil
            processedIdentity = nil
            latestDocuments = nil
            controller.stop()
            controller.onChange = nil
            if let cancellationID {
                store?.unregisterCancellation(cancellationID)
            }
            cancellationID = nil
            store = nil
            session = nil
            request = nil
            if snapshot != nil {
                snapshot = nil
            }
            if error != nil {
                error = nil
            }
            isLoading = false
            isProcessing = false
        }

        /// Start a fresh listener after a transport or processing error.
        func retry() {
            guard let request, let store else {
                return
            }
            stop()
            update(request: request, store: store)
        }

        func fail(_ error: any Swift.Error, clear: Bool) {
            if clear, store == nil, snapshot == nil, let newError = error as? Error,
               self.error as? Error == newError {
                return
            }
            if clear {
                stop()
            } else {
                generation += 1
                processingTask?.cancel()
                processingTask = nil
                processingIdentity = nil
            }
            self.error = error
            isLoading = false
            isProcessing = false
            onChange?(.failure(error))
        }

        private func receive(_ result: Result<MHCFirestoreSnapshot<StatsDocument>, any Swift.Error>) {
            guard let store, let session, let request else {
                return
            }
            do {
                try store.validate(session)
                let documents = try result.get()
                latestDocuments = documents
                let identity = ProcessingIdentity(contentRevision: documents.contentRevision, request: request)
                if processingIdentity == identity {
                    // Preserve the work already in flight; it will publish with the newest metadata.
                    return
                }
                if processedIdentity == identity, let snapshot {
                    publish(snapshot.updatingMetadata(from: documents))
                    return
                }
                process(documents, identity: identity, store: store, session: session)
            } catch {
                fail(error, clear: error is Error)
            }
        }

        private func process(
            _ documents: MHCFirestoreSnapshot<StatsDocument>,
            identity: ProcessingIdentity,
            store: StatsStore,
            session: Session
        ) {
            generation += 1
            let generation = generation
            processingTask?.cancel()
            processingIdentity = identity
            isLoading = snapshot == nil
            isProcessing = snapshot != nil
            processingTask = Task { [weak self] in
                do {
                    try store.validate(session)
                    let snapshot = try await StatsStore.process(documents, request: identity.request)
                    try Task.checkCancellation()
                    try store.validate(session)
                    guard let self, generation == self.generation, let latest = self.latestDocuments else {
                        return
                    }
                    self.processingIdentity = nil
                    self.processingTask = nil
                    self.processedIdentity = identity
                    self.publish(snapshot.updatingMetadata(from: latest))
                } catch {
                    guard let self, generation == self.generation, !Task.isCancelled else {
                        return
                    }
                    self.fail(error, clear: error is Error)
                }
            }
        }

        private func publish(_ snapshot: Snapshot<Element>) {
            self.snapshot = snapshot
            error = nil
            isLoading = false
            isProcessing = false
            onChange?(.success(snapshot))
        }

        isolated deinit {
            processingTask?.cancel()
            controller.stop()
            if let cancellationID {
                store?.unregisterCancellation(cancellationID)
            }
        }
    }
}
