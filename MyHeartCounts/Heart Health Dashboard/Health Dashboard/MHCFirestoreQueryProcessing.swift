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
import SpeziFoundation


/// One listener delivery, separating document contents from query metadata.
struct MHCFirestoreQueryInput: Sendable {
    let documents: [QueryDocumentSnapshot]
    let isFromCache: Bool
    let hasPendingWrites: Bool
    let hasDocumentChanges: Bool

    init(_ snapshot: QuerySnapshot) {
        documents = snapshot.documents
        isFromCache = snapshot.metadata.isFromCache
        hasPendingWrites = snapshot.metadata.hasPendingWrites
        hasDocumentChanges = !snapshot.documentChanges(includeMetadataChanges: false).isEmpty
    }

    init(documents: [QueryDocumentSnapshot], isFromCache: Bool, hasPendingWrites: Bool, hasDocumentChanges: Bool) {
        self.documents = documents
        self.isFromCache = isFromCache
        self.hasPendingWrites = hasPendingWrites
        self.hasDocumentChanges = hasDocumentChanges
    }
}


/// A decoded snapshot and the metadata needed to assess its freshness and completeness.
struct MHCFirestoreSnapshot<Element: Sendable>: Sendable {
    let elements: [Element]
    let isFromCache: Bool
    let hasPendingWrites: Bool
    /// Documents rejected by the decoder; successfully decoded documents remain available.
    let failedDocumentCount: Int
    /// Identifies the decoded contents; metadata-only deliveries preserve this revision.
    let contentRevision: UUID

    init(elements: [Element], isFromCache: Bool, hasPendingWrites: Bool, failedDocumentCount: Int, contentRevision: UUID = UUID()) {
        self.elements = elements
        self.isFromCache = isFromCache
        self.hasPendingWrites = hasPendingWrites
        self.failedDocumentCount = failedDocumentCount
        self.contentRevision = contentRevision
    }

    func updatingMetadata(from input: MHCFirestoreQueryInput) -> Self {
        Self(
            elements: elements,
            isFromCache: input.isFromCache,
            hasPendingWrites: input.hasPendingWrites,
            failedDocumentCount: failedDocumentCount,
            contentRevision: contentRevision
        )
    }
}


/// Client-side interpretation, independently comparable from the server-side query.
struct MHCFirestoreQueryProcessing<Element: Sendable>: Equatable, Sendable {
    private let decoder: any MyHeartCountsShared.ValueTransformer<QueryDocumentSnapshot, Element>
    private let sort: [any SortComparator<Element>]
    private let limit: Int?
    /// Opt in only when the decoder's output does not depend on document metadata.
    /// Generic transformers may inspect metadata, so they decode every delivery by default.
    let ignoresDocumentMetadata: Bool

    init(
        decoder: some MyHeartCountsShared.ValueTransformer<QueryDocumentSnapshot, Element>,
        sort: [any SortComparator<Element>] = [],
        limit: Int? = nil,
        ignoresDocumentMetadata: Bool = false
    ) {
        self.decoder = decoder
        self.sort = sort
        self.limit = limit
        self.ignoresDocumentMetadata = ignoresDocumentMetadata
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.decoder.isEqual(rhs.decoder)
            && lhs.sort.elementsEqual(rhs.sort, by: { $0.isEqual($1) })
            && lhs.limit == rhs.limit
            && lhs.ignoresDocumentMetadata == rhs.ignoresDocumentMetadata
    }

    @concurrent
    func decode(_ snapshot: MHCFirestoreQueryInput) async -> MHCFirestoreSnapshot<Element> {
        var elements: [Element] = []
        var failedDocumentCount = 0
        elements.reserveCapacity(snapshot.documents.count)
        for document in snapshot.documents {
            do {
                elements.append(try decoder.transform(document))
            } catch {
                failedDocumentCount += 1
            }
        }
        elements.sort(using: sort)
        if let limit, limit >= 0, limit < elements.count {
            // Preserve the wrapper's existing client-side limit semantics.
            elements.removeFirst(elements.count - limit)
        }
        return MHCFirestoreSnapshot(
            elements: elements,
            isFromCache: snapshot.isFromCache,
            hasPendingWrites: snapshot.hasPendingWrites,
            failedDocumentCount: failedDocumentCount
        )
    }
}
