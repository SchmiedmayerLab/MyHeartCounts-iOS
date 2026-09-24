//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import FirebaseFirestore
import Foundation


/// The server-side query, with an explicitly resolved collection path.
struct MHCFirestoreQuerySpecification: Hashable, Sendable {
    enum Filter: Hashable, Sendable {
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

    struct SortDescriptor: Hashable, Sendable {
        let fieldName: String
        let order: SortOrder
    }

    let collectionPath: String
    var filter: Filter?
    var sort: [SortDescriptor] = []
    var limit: Int?

    func query(in firestore: Firestore) -> Query {
        var query: Query = firestore.collection(collectionPath)
        if let filter {
            query = query.whereFilter(filter.firestoreFilter)
        }
        for descriptor in sort {
            query = query.order(by: descriptor.fieldName, descending: descriptor.order == .reverse)
        }
        if let limit, limit > 0 {
            query = query.limit(to: limit)
        }
        return query
    }
}
