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
import Spezi
import SpeziAccount
import SpeziFoundation


/// Account-bound access to stats from modules, background tasks, and SwiftUI.
@Observable
@MainActor
final class StatsStore: Module, EnvironmentAccessible {
    /// Where a one-shot stats read may obtain its documents.
    enum ReadPolicy: Sendable {
        case server
        case serverOrCache
        case cache

        fileprivate var firestoreSource: FirestoreSource {
            switch self {
            case .server: .server
            case .serverOrCache: .default
            case .cache: .cache
            }
        }
    }

    enum Error: Swift.Error, Equatable {
        case notSignedIn
        case sessionChanged
        case unavailable
        case invalidDocument
    }

    struct Session: Equatable {
        let accountID: String
        let backendID: ObjectIdentifier
        let revision: Int
        let cleanupGeneration: Int
    }

    private struct DocumentDecoder: MyHeartCountsShared.ValueTransformer {
        let metricId: HealthKitStatsCalculator.MetricID

        func transform(_ document: QueryDocumentSnapshot) throws -> StatsDocument {
            let decoded = try document.data(as: StatsDocument.self)
            guard decoded.version == 0, decoded.metric == metricId.rawValue else {
                throw Error.invalidDocument
            }
            return decoded
        }
    }

    @Dependency(Account.self)
    @ObservationIgnored private var account: Account?
    @ObservationIgnored private let suppliedContext: (@MainActor () -> (Firestore, String?))?
    @ObservationIgnored private var cancellations: [UUID: @MainActor () -> Void] = [:]
    @ObservationIgnored private var suspendedAccountID: String?
    /// Observed by the SwiftUI adapter so it can subscribe again after an account transition.
    private(set) var sessionRevision = 0

    init() {
        suppliedContext = nil
    }

    /// Explicit dependencies for isolated clients and tests, without requiring a SwiftUI or Spezi environment.
    init(firestore: Firestore, accountID: @escaping @MainActor () -> String?) {
        suppliedContext = { (firestore, accountID()) }
    }

    /// Fetch once, preserving the account session even while awaiting network or decoding work.
    func fetch<Element>(
        _ request: Request<Element>,
        readPolicy: ReadPolicy = .serverOrCache
    ) async throws -> Snapshot<Element> {
        try Task.checkCancellation()
        let (firestore, session) = try context()
        let task = Task {
            let documents = try await MHCFirestoreQueryController<StatsDocument>.fetch(
                firestore: firestore,
                query: Self.query(for: request, accountID: session.accountID),
                processing: Self.processing(for: request),
                source: readPolicy.firestoreSource
            )
            return try await Self.process(documents, request: request)
        }
        let cancellationID = registerCancellation { task.cancel() }
        defer { unregisterCancellation(cancellationID) }
        do {
            let snapshot = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            try Task.checkCancellation()
            try validate(session)
            return snapshot
        } catch {
            try validate(session)
            throw error
        }
    }

    /// Creates an independent subscription. Cancelling its consuming task removes the listener.
    /// When leaving a loop early, release its stream and iterator; cancelling an already-finished task does not dispose a retained stream.
    func updates<Element>(for request: Request<Element>) -> AsyncThrowingStream<Snapshot<Element>, any Swift.Error> {
        let (stream, continuation) = AsyncThrowingStream<Snapshot<Element>, any Swift.Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let observation = Subscription<Element>()
        continuation.onTermination = { @Sendable _ in
            Task { @MainActor in observation.stop() }
        }
        observation.onChange = { result in
            switch result {
            case .success(let snapshot): continuation.yield(snapshot)
            case .failure(let error): continuation.finish(throwing: error)
            }
        }
        observation.update(request: request, store: self)
        return stream
    }

    /// Called synchronously by the app's account event handler before its asynchronous cleanup.
    func handleAccountEvent(_ event: AccountNotifications.Event) {
        switch event {
        case .associatedAccount:
            suspendedAccountID = nil
            invalidateSession()
        case .disassociatingAccount, .deletingAccount:
            invalidateSession()
        case let .detailsChanged(previous, current):
            if previous.accountId != current.accountId {
                suspendedAccountID = nil
                invalidateSession()
            }
        }
    }

    /// Prevent SwiftUI from reopening the old account's query while sign-out awaits network cleanup.
    func prepareForLogout() {
        if let current = try? context().1.accountID {
            suspendedAccountID = current
        }
        invalidateSession()
    }

    func invalidateSession() {
        sessionRevision += 1
        let pending = Array(cancellations.values)
        cancellations.removeAll()
        for cancel in pending {
            cancel()
        }
    }

    func context() throws -> (Firestore, Session) {
        let firestore: Firestore
        let accountID: String?
        if let suppliedContext {
            (firestore, accountID) = suppliedContext()
        } else {
            accountID = account?.details?.accountId
            guard accountID != nil else {
                throw Error.notSignedIn
            }
            firestore = Firestore.firestore()
        }
        guard let accountID else {
            throw Error.notSignedIn
        }
        guard accountID != suspendedAccountID else {
            throw Error.sessionChanged
        }
        return (firestore, Session(
            accountID: accountID,
            backendID: ObjectIdentifier(firestore),
            revision: sessionRevision,
            cleanupGeneration: suppliedContext == nil ? LocalPreferencesStore.standard[.accountDataGeneration] : 0
        ))
    }

    func validate(_ session: Session) throws {
        guard let (_, current) = try? context(), current == session else {
            throw Error.sessionChanged
        }
    }

    func registerCancellation(_ cancel: @escaping @MainActor () -> Void) -> UUID {
        let id = UUID()
        cancellations[id] = cancel
        return id
    }

    func unregisterCancellation(_ id: UUID) {
        cancellations[id] = nil
    }
}


extension StatsStore {
    /// A processed snapshot, including information needed to interpret incomplete or approximate results.
    struct Snapshot<Element: Sendable>: Sendable {
        let elements: [Element]
        let diagnostics: [Diagnostic]
        let contributingSourceIDs: Set<StatsDocument.SourceID>
        let isFromCache: Bool
        let hasPendingWrites: Bool

        func updatingMetadata(from documents: MHCFirestoreSnapshot<StatsDocument>) -> Self {
            Self(
                elements: elements,
                diagnostics: diagnostics,
                contributingSourceIDs: contributingSourceIDs,
                isFromCache: documents.isFromCache,
                hasPendingWrites: documents.hasPendingWrites
            )
        }
    }
}


extension StatsStore {
    static func query<Element>(for request: Request<Element>, accountID: String) -> MHCFirestoreQuerySpecification {
        MHCFirestoreQuerySpecification(
            collectionPath: "users/\(accountID)/stats/\(request.metricId.rawValue)/months",
            filter: .documentId(in: request.monthDocumentIdBounds() ?? "0000-00"..."0000-00")
        )
    }

    static func processing<Element>(for request: Request<Element>) -> MHCFirestoreQueryProcessing<StatsDocument> {
        MHCFirestoreQueryProcessing(decoder: DocumentDecoder(metricId: request.metricId), ignoresDocumentMetadata: true)
    }

    @concurrent
    static func process<Element>(
        _ documents: MHCFirestoreSnapshot<StatsDocument>,
        request: Request<Element>
    ) async throws -> Snapshot<Element> {
        try Task.checkCancellation()
        let result = try request.process(documents.elements)
        var diagnostics = result.diagnostics
        if documents.failedDocumentCount > 0 {
            diagnostics.append(.invalidDocumentCount(documents.failedDocumentCount))
        }
        try Task.checkCancellation()
        return Snapshot(
            elements: result.elements,
            diagnostics: diagnostics,
            contributingSourceIDs: result.contributingSourceIDs,
            isFromCache: documents.isFromCache,
            hasPendingWrites: documents.hasPendingWrites
        )
    }
}
