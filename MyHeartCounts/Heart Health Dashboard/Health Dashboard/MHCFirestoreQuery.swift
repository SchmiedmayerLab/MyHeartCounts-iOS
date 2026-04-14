//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import FirebaseFirestore
import Foundation
import SpeziHealthKitFHIR
import struct ModelsR4.DateTime
import struct ModelsR4.FHIRPrimitive
import struct ModelsR4.FHIRURI
import class ModelsR4.Period
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
@MainActor
@propertyWrapper
struct MHCFirestoreQuery<Element: Sendable>: DynamicProperty {
    typealias DecodeFn = @Sendable (QueryDocumentSnapshot) -> Element?
    
    /// The collection which should be queried
    enum Collection {
        /// The query should observe `users/{USER}/{path}`, where `USER` is the account id of the currently logged in user.
        case user(path: String)
        /// The query should observe the collection at `path`.
        case root(path: String)
    }
    
    @Environment(Account.self)
    private var account: Account?
    
    @State private var impl = Impl()
    private let input: QueryInput
    private let logger = Logger(category: .init("MHCFirestoreQuery<\(Element.self)>"))
    
    var wrappedValue: [Element] {
        impl.elements
    }
    
    init(
        _: Element.Type = Element.self,
        collection: Collection,
        filter: Filter? = nil,
        sortBy sortDescriptors: [SortDescriptor] = [],
        limit: Int? = nil,
        decode: @escaping DecodeFn
    ) {
        self.init(
            Element.self,
            collection: collection,
            preDecodeFilter: filter,
            preDecodeSort: sortDescriptors,
            preDecodeLimit: limit,
            decode: decode,
            postDecodeSort: [],
            postDecodeLimit: nil
        )
    }
    
    @_disfavoredOverload
    init(
        _: Element.Type = Element.self,
        collection: Collection,
        decode: @escaping DecodeFn,
        sort: [any SortComparator<Element>] = [],
        limit: Int? = nil
    ) {
        self.init(
            Element.self,
            collection: collection,
            preDecodeFilter: nil,
            preDecodeSort: [],
            preDecodeLimit: nil,
            decode: decode,
            postDecodeSort: sort,
            postDecodeLimit: limit
        )
    }
    
    
    private init(
        _: Element.Type = Element.self,
        collection: Collection,
        preDecodeFilter: Filter?,
        preDecodeSort: [SortDescriptor],
        preDecodeLimit: Int?,
        decode: @escaping DecodeFn,
        postDecodeSort: [any SortComparator<Element>],
        postDecodeLimit: Int?
    ) {
        input = .init(
            collection: collection,
            preDecodeFilter: preDecodeFilter,
            preDecodeSort: preDecodeSort,
            preDecodeLimit: preDecodeLimit,
            decode: decode,
            postDecodeSort: postDecodeSort,
            postDecodeLimit: postDecodeLimit
        )
    }
    
    nonisolated func update() {
        var input = self.input
        Task { @MainActor in
            switch input.collection {
            case .user(let path):
                guard let accountId = account?.details?.accountId else {
                    logger.error("Asked to query in user collection, but no user logged in. (path: \(path))")
                    return
                }
                input.collection = .root(path: "users/\(accountId)/" + path)
            case .root:
                break
            }
            impl.setup(input: input, logger: logger)
        }
    }
}


extension MHCFirestoreQuery {
    struct SortDescriptor: Sendable {
        let fieldName: String
        let order: SortOrder
    }
    
    fileprivate struct QueryInput: Sendable {
        var collection: Collection
        var preDecodeFilter: Filter?
        var preDecodeSort: [SortDescriptor]
        var preDecodeLimit: Int?
        var decode: DecodeFn
        var postDecodeSort: [any SortComparator<Element>] = []
        var postDecodeLimit: Int?
    }
}


extension MHCFirestoreQuery {
    @Observable
    @MainActor
    fileprivate final class Impl: Sendable {
        typealias QueryInput = MHCFirestoreQuery<Element>.QueryInput
        
        @ObservationIgnored private var listener: (any ListenerRegistration)?
        private(set) var elements: [Element] = []
        
        func setup(input: QueryInput, logger: Logger) {
            guard listener == nil else {
                return
            }
            listener?.remove()
            var query: Query
            switch input.collection {
            case .root(let path):
                query = Firestore.firestore().collection(path)
            default:
                // unreachable
                logger.error("[impl] skipping setup request bc input contains an unresolved path.")
                return
            }
            if let filter = input.preDecodeFilter {
                query = query.whereFilter(filter)
            }
            for sortDescriptor in input.preDecodeSort {
                query = query.order(by: sortDescriptor.fieldName, descending: sortDescriptor.order == .reverse)
            }
            if let limit = input.preDecodeLimit, limit > 0 {
                query = query.limit(to: limit)
            }
            listener = query.addSnapshotListener { @Sendable [weak self] snapshot, error in
                guard let self else {
                    return
                }
                if let snapshot {
                    Task {
                        await self.handleSnapshot(snapshot, input: input)
                    }
                } else if let error {
                    logger.error("encountered error in firebase snapshot listener: \(error)")
                }
            }
        }
        
        @concurrent
        private func handleSnapshot(_ snapshot: QuerySnapshot, input: QueryInput) async {
            var elements = await self.elements
            elements.removeAll(keepingCapacity: true)
            for document in snapshot.documents {
                if let element = input.decode(document) {
                    elements.append(element)
                }
            }
            elements.sort(using: input.postDecodeSort)
            if let limit = input.postDecodeLimit, limit > elements.count {
                elements.removeFirst(elements.count - limit)
            }
            await MainActor.run {
                self.elements = elements
            }
        }
    }
}


// MARK: Extensions

extension MHCFirestoreQuery {
    init(
        sampleTypeIdentifier: String,
        timeRange: HealthKitQueryTimeRange,
        sorted sortDescriptors: [any SortComparator<Element>] = [],
        limit: Int? = nil,
        transform: @escaping @Sendable (ResourceProxy) -> Element?
    ) {
        self.init(
            collection: .user(path: "HealthObservations_\(sampleTypeIdentifier)"),
            decode: { document -> Element? in
                if timeRange != .ever {
                    let data = document.data()
                    if let dateString = data["effectiveDateTime"] as? String {
                        guard let date = try? DateTime(dateString).asNSDate() else {
                            return nil
                        }
                        guard timeRange.range.contains(date) else {
                            return nil
                        }
                    } else if let periodDict = data["effectivePeriod"] as? [String: String] {
                        guard let start = periodDict["start"].flatMap({ try? DateTime($0).asNSDate() }),
                              let end = periodDict["end"].flatMap({ try? DateTime($0).asNSDate() }) else {
                            return nil
                        }
                        guard (start..<end).overlaps(timeRange.range) else {
                            return nil
                        }
                    } else {
                        // we want to filter based on time range, but we can't extract a time range to filter against from the document
                        return nil
                    }
                }
                guard let proxy = try? document.data(as: ResourceProxy.self) else {
                    return nil
                }
                return transform(proxy)
            },
            sort: sortDescriptors,
            limit: limit
        )
    }
}


extension MHCFirestoreQuery where Element == QuantitySample {
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
            limit: limit
        ) { resourceProxy in
            QuantitySample(resourceProxy, sampleTypeHint: .custom(sampleType))
        }
    }
}
