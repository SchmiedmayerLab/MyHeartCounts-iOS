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
import SpeziAccount
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
    typealias Filter = MHCFirestoreQuerySpecification.Filter
    typealias SortDescriptor = MHCFirestoreQuerySpecification.SortDescriptor
    
    /// The collection which should be queried
    enum Collection: Hashable, Sendable {
        /// The query should observe `users/{USER}/{path}`, where `USER` is the account id of the currently logged in user.
        case user(path: String)
        /// The query should observe the collection at `path`.
        case root(path: String)
    }
    
    @Environment(Account.self)
    private var account: Account?
    
    @State private var impl = MHCFirestoreQueryController<Element>(includeMetadataChanges: false)
    /// The firebase side of the query
    private let querySpec: FirebaseQuerySpec
    /// The client side of the query
    private let queryPostProcessingSpec: MHCFirestoreQueryProcessing<Element>
    
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
        queryPostProcessingSpec = MHCFirestoreQueryProcessing(
            decoder: decoder,
            sort: postDecodeSort,
            limit: postDecodeLimit
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
        guard case .root(let path) = querySpec.collection else {
            return
        }
        impl.setup(
            firestore: Firestore.firestore(),
            query: MHCFirestoreQuerySpecification(
                collectionPath: path, filter: querySpec.filter, sort: querySpec.sort, limit: querySpec.limit
            ),
            processing: queryPostProcessingSpec
        )
    }
}


extension MHCFirestoreQuery {
    private struct FirebaseQuerySpec: Hashable, Sendable {
        var collection: Collection
        var filter: Filter?
        var sort: [SortDescriptor]
        var limit: Int?
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
