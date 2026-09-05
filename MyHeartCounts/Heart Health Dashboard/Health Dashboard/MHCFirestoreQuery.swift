//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import FirebaseFirestore
import Foundation
import struct ModelsR4.DateTime
import struct ModelsR4.FHIRPrimitive
import struct ModelsR4.FHIRURI
import struct ModelsR4.Period
import enum ModelsR4.ResourceProxy
import MyHeartCountsShared
import OSLog
import SpeziAccount
import SpeziFoundation
import SpeziHealthKit
import SwiftUI


/// Query data from Firestore.
///
/// An alternative to Firebase's `FirestoreQuery`, with some changes based on our specific needs in My Heart Counts:
///
/// Differences to the `@FirestoreQuery` API:
/// - ability to not only transform the documents into a custom `Decodable` type, but then (optionally) also implicitly project into a different type from that
///     (required bc we don't want to have to operate directly on FHIR Observations and eg want to turn them into our ``QuantitySample``s instead)
///
/// - Note: The ``MHCFirestoreQuery`` APIs intentionally use `ValueTransformer`s instead of regular closures to customize decoding;
///     the reason being that closures cannot be `Equatable`, which is important for the query to be able to skip unnecessary updates
///     if it is recreated with identical inputs (in which case the previously-created underlying firestore query can be kept around).
@MainActor
@propertyWrapper
struct MHCFirestoreQuery<Element: Sendable>: DynamicProperty {
    typealias ValueTransformer = MyHeartCountsShared.ValueTransformer
    
    /// The collection which should be queried
    enum Collection: Hashable, Sendable {
        /// The query should observe `users/{USER}/{path}`, where `USER` is the account id of the currently logged in user.
        case user(path: String)
        /// The query should observe the collection at `path`.
        case root(path: String)
    }
    
    /// A server-side filter on the queried collection.
    ///
    /// Modelled as a value rather than a `FirebaseFirestore.Filter`, so that the query specification stays `Hashable`:
    /// that is what lets the wrapper tell a genuinely changed query apart from its view merely being re-evaluated.
    enum Filter: Hashable, Sendable {
        /// Restricts the query to the documents whose id lies within the range.
        case documentId(in: ClosedRange<String>)
        
        fileprivate var firestoreFilter: FirebaseFirestore.Filter {
            switch self {
            case .documentId(let range):
                .andFilter([
                    .whereField(FieldPath.documentID(), isGreaterOrEqualTo: range.lowerBound),
                    .whereField(FieldPath.documentID(), isLessThanOrEqualTo: range.upperBound)
                ])
            }
        }
    }
    
    
    @Environment(Account.self)
    private var account: Account?
    
    @State private var impl = Impl()
    /// The firebase side of the query
    private let querySpec: FirebaseQuerySpec
    /// The client side of the query
    private let queryPostProcessingSpec: PostQueryProcessingSpec
    
    private let logger = Logger(category: .init("MHCFirestoreQuery<\(Element.self)>"))
    
    var wrappedValue: [Element] {
        // we need to access the accountId here to have the query auto-update if it changes,
        // e.g. when the user is logged out/in while the query is installed on a view.
        _ = account?.details?.accountId
        return impl.elements
    }
    
    init(
        _: Element.Type = Element.self,
        collection: Collection,
        filter: Filter? = nil,
        sortBy sortDescriptors: [SortDescriptor] = [],
        limit: Int? = nil,
        decoder: some ValueTransformer<QueryDocumentSnapshot, Element>
    ) {
        self.init(
            collection: collection,
            preDecodeFilter: filter,
            preDecodeSort: sortDescriptors,
            preDecodeLimit: limit,
            decoder: decoder,
            postDecodeSort: [],
            postDecodeLimit: nil
        )
    }
    
    @_disfavoredOverload
    init(
        _: Element.Type = Element.self,
        collection: Collection,
        decoder: some ValueTransformer<QueryDocumentSnapshot, Element>,
        sort: [any SortComparator<Element>] = [],
        limit: Int? = nil
    ) {
        self.init(
            collection: collection,
            preDecodeFilter: nil,
            preDecodeSort: [],
            preDecodeLimit: nil,
            decoder: decoder,
            postDecodeSort: sort,
            postDecodeLimit: limit
        )
    }
    
    
    private init(
        collection: Collection,
        preDecodeFilter: Filter?,
        preDecodeSort: [SortDescriptor],
        preDecodeLimit: Int?,
        decoder: some ValueTransformer<QueryDocumentSnapshot, Element>,
        postDecodeSort: [any SortComparator<Element>],
        postDecodeLimit: Int?
    ) {
        querySpec = FirebaseQuerySpec(
            collection: collection,
            filter: preDecodeFilter,
            sort: preDecodeSort,
            limit: preDecodeLimit
        )
        queryPostProcessingSpec = PostQueryProcessingSpec(
            decoder: decoder,
            postDecodeSort: postDecodeSort,
            postDecodeLimit: postDecodeLimit
        )
    }
    
    nonisolated func update() {
        MainActor.assumeIsolated {
            self._update()
        }
    }
    
    @MainActor
    private func _update() {
        var querySpec = querySpec
        switch querySpec.collection {
        case .user(let path):
            guard let accountId = account?.details?.accountId else {
                // if no user is available, we stop the underlying query.
                // since we access `account.details.accountId` in `wrappedValue`,
                // the query will auto-restart when the user logs back in.
                impl.stop()
                return
            }
            querySpec.collection = .root(path: "users/\(accountId)/" + path)
        case .root:
            break
        }
        impl.setup(querySpec: querySpec, postProcessingSpec: queryPostProcessingSpec, logger: logger)
    }
}


extension MHCFirestoreQuery {
    struct SortDescriptor: Hashable, Sendable {
        let fieldName: String
        let order: SortOrder
    }
    
    /// The server-side half of a query: everything that determines which documents the snapshot listener receives, and how they are filtered/sorted/etc while still in firebase-land.
    ///
    /// Being `Hashable` is what makes it possible to keep the listener across view updates, and to replace it exactly when the query changed.
    fileprivate struct FirebaseQuerySpec: Hashable, Sendable {
        var collection: Collection
        var filter: Filter?
        var sort: [SortDescriptor]
        var limit: Int?
    }
    
    
    /// The client-side half of a query: how the received documents are turned into elements.
    fileprivate struct PostQueryProcessingSpec: Equatable, Sendable {
        private let decoder: any ValueTransformer<QueryDocumentSnapshot, Element>
        let postDecodeSort: [any SortComparator<Element>]
        let postDecodeLimit: Int?
        
        init(
            decoder: some ValueTransformer<QueryDocumentSnapshot, Element>,
            postDecodeSort: [any SortComparator<Element>],
            postDecodeLimit: Int?
        ) {
            self.decoder = decoder
            self.postDecodeSort = postDecodeSort
            self.postDecodeLimit = postDecodeLimit
        }
        
        static func == (lhs: Self, rhs: Self) -> Bool {
            if !lhs.decoder.isEqual(rhs.decoder) {
                return false
            }
            if !lhs.postDecodeSort.elementsEqual(rhs.postDecodeSort, by: { $0.isEqual($1) }) {
                return false
            }
            if lhs.postDecodeLimit != rhs.postDecodeLimit {
                return false
            }
            return true
        }
        
        func decode(_ document: QueryDocumentSnapshot) -> Element? {
            try? decoder.transform(document)
        }
    }
}


extension MHCFirestoreQuery {
    @Observable
    @MainActor
    fileprivate final class Impl: Sendable {
        typealias FirebaseQuerySpec = MHCFirestoreQuery<Element>.FirebaseQuerySpec
        typealias PostQueryProcessingSpec = MHCFirestoreQuery<Element>.PostQueryProcessingSpec
        
        @ObservationIgnored private var listener: (any ListenerRegistration)?
        /// The specification the current listener was created for.
        @ObservationIgnored private var activeQuerySpec: FirebaseQuerySpec?
        /// Bumped whenever the listener is replaced, so that snapshots of a previous listener that are still being delivered get dropped.
        @ObservationIgnored private var listenerGeneration = 0
        /// The most recent snapshot, kept so that it can be decoded again when the decode parameters change.
        @ObservationIgnored private var lastSnapshot: QuerySnapshot?
        /// The most recently supplied processing, applied to the next decode.
        @ObservationIgnored private var postProcessingSpec: PostQueryProcessingSpec?
        /// snapshot generation counter, so that out-of-order decode completions can't overwrite newer data with older data
        @ObservationIgnored private var snapshotGeneration = 0
        private(set) var elements: [Element] = []
        
        func setup(querySpec: FirebaseQuerySpec, postProcessingSpec: PostQueryProcessingSpec, logger: Logger) {
            let oldPostProcessingSpec = self.postProcessingSpec
            // always adopt the latest processing; it is what the next decode uses.
            self.postProcessingSpec = postProcessingSpec
            guard querySpec == activeQuerySpec else {
                replaceListener(with: querySpec, logger: logger)
                return
            }
            if let oldPostProcessingSpec, postProcessingSpec == oldPostProcessingSpec {
                // the view was re-evaluated, but nothing about the query changed: keep both the listener and the elements.
                return
            }
            // Immediately invalidate in-flight decoding that used the previous processing specification.
            snapshotGeneration += 1
            let scheduledGeneration = snapshotGeneration
            // the query is the same, but its documents need to be interpreted differently: decode the ones we already have again.
            if let lastSnapshot {
                let listenerGeneration = listenerGeneration
                Task {
                    guard scheduledGeneration == self.snapshotGeneration else {
                        return
                    }
                    await process(lastSnapshot, from: listenerGeneration)
                }
            }
        }
        
        /// Stops the query, and clears all previously-fetched elements.
        func stop() {
            exchange(&listener, with: nil)?.remove()
            activeQuerySpec = nil
            lastSnapshot = nil
            postProcessingSpec = nil
            // Reject callbacks and decode results from the previous query.
            listenerGeneration += 1
            snapshotGeneration += 1
            // remove fetched elements
            if !elements.isEmpty {
                elements.removeAll()
            }
        }
        
        private func replaceListener(with querySpec: FirebaseQuerySpec, logger: Logger) {
            listener?.remove()
            listener = nil
            activeQuerySpec = querySpec
            listenerGeneration += 1
            let listenerGeneration = listenerGeneration
            // whatever the previous query delivered doesn't belong to this one.
            lastSnapshot = nil
            snapshotGeneration += 1
            elements = []
            var query: Query
            switch querySpec.collection {
            case .root(let path):
                query = Firestore.firestore().collection(path)
            default:
                // unreachable
                logger.error("[impl] skipping setup request bc input contains an unresolved path.")
                return
            }
            if let filter = querySpec.filter {
                query = query.whereFilter(filter.firestoreFilter)
            }
            for sortDescriptor in querySpec.sort {
                query = query.order(by: sortDescriptor.fieldName, descending: sortDescriptor.order == .reverse)
            }
            if let limit = querySpec.limit, limit > 0 {
                query = query.limit(to: limit)
            }
            listener = query.addSnapshotListener { @Sendable [weak self] snapshot, error in
                guard let self else {
                    return
                }
                if let snapshot {
                    Task {
                        await self.process(snapshot, from: listenerGeneration)
                    }
                } else if let error {
                    logger.error("encountered error in firebase snapshot listener: \(error)")
                }
            }
        }
        
        private func process(_ snapshot: QuerySnapshot, from listenerGeneration: Int) async {
            guard listenerGeneration == self.listenerGeneration, let postProcessingSpec else {
                // the listener that delivered this snapshot has since been replaced
                return
            }
            lastSnapshot = snapshot
            snapshotGeneration += 1
            let generation = snapshotGeneration
            let elements = await decode(snapshot, using: postProcessingSpec)
            guard generation == snapshotGeneration else {
                // a newer snapshot (or a newer set of parameters) was already processed
                return
            }
            self.elements = elements
        }
        
        @concurrent
        private func decode(_ snapshot: QuerySnapshot, using spec: PostQueryProcessingSpec) async -> [Element] {
            var elements: [Element] = []
            elements.reserveCapacity(snapshot.documents.count)
            for document in snapshot.documents {
                if let element = spec.decode(document) {
                    elements.append(element)
                }
            }
            elements.sort(using: spec.postDecodeSort)
            if let limit = spec.postDecodeLimit, limit < elements.count {
                elements.removeFirst(elements.count - limit)
            }
            return elements
        }
        
        // dropping a `ListenerRegistration` does not detach the listener; it needs an explicit `remove()` call.
        // (the deinit needs to be isolated so that it can access the non-Sendable `listener` property.)
        isolated deinit {
            listener?.remove()
        }
    }
}

// MARK: Extensions

extension MHCFirestoreQuery {
    private struct ResourceProxyDecoder: ValueTransformer<QueryDocumentSnapshot, ResourceProxy> {
        private struct TransformFailed: Error {}
        
        let timeRange: HealthKitQueryTimeRange
        
        func transform(_ input: QueryDocumentSnapshot) throws -> ResourceProxy {
            if timeRange != .ever {
                let data = input.data()
                if let dateString = data["effectiveDateTime"] as? String {
                    let date = try DateTime(dateString).asNSDate()
                    guard timeRange.range.contains(date) else {
                        throw TransformFailed()
                    }
                } else if let periodDict = data["effectivePeriod"] as? [String: String] {
                    guard let start = periodDict["start"].flatMap({ try? DateTime($0).asNSDate() }),
                          let end = periodDict["end"].flatMap({ try? DateTime($0).asNSDate() }) else {
                        throw TransformFailed()
                    }
                    guard (start..<end).overlaps(timeRange.range) else {
                        throw TransformFailed()
                    }
                } else {
                    // we want to filter based on time range, but we can't extract a time range to filter against from the document
                    throw TransformFailed()
                }
            }
            return try input.data(as: ResourceProxy.self)
        }
    }
    
    
    init(
        sampleTypeIdentifier: String,
        timeRange: HealthKitQueryTimeRange,
        sorted sortDescriptors: [any SortComparator<Element>] = [],
        limit: Int? = nil,
        transform: some MyHeartCountsShared.ValueTransformer<ResourceProxy, Element>
    ) {
        self.init(
            collection: .user(path: "HealthObservations_\(sampleTypeIdentifier)"),
            decoder: ResourceProxyDecoder(timeRange: timeRange).concat(transform),
            sort: sortDescriptors,
            limit: limit
        )
    }
}


extension MHCFirestoreQuery where Element == QuantitySample {
    private struct QuantitySampleTransformer: ValueTransformer<ResourceProxy, Element> {
        struct FailedToCreateSample: Error {}
        
        let sampleTypeHint: MHCQuantitySampleType
        
        func transform(_ input: ResourceProxy) throws -> QuantitySample {
            if let sample = QuantitySample(input, sampleTypeHint: sampleTypeHint) {
                return sample
            } else {
                throw FailedToCreateSample()
            }
        }
    }
    
    init(
        sampleType: CustomQuantitySampleType,
        timeRange: HealthKitQueryTimeRange,
        sorted sortDescriptor: some SortComparator<QuantitySample> = KeyPathComparator(\.startDate, order: .reverse),
        limit: Int? = nil
    ) {
        self.init(
            sampleTypeIdentifier: sampleType.id,
            timeRange: timeRange,
            sorted: [sortDescriptor],
            limit: limit,
            transform: QuantitySampleTransformer(sampleTypeHint: .custom(sampleType))
        )
    }
}
