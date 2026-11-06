//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import MyHeartCountsShared
import OSLog


/// What one drained chunk did that no healthy chunk does: a producer integrity failure, reported once per kind per chunk.
///
/// It carries no sample, record or node identifier.
struct HealthUploadIntegrityEvent: Sendable, Equatable {
    enum Kind: String, Sendable, CaseIterable {
        /// A record's shared node has other bytes than a packed record's, so the record started a fresh Bundle.
        case conflictingNode
        /// A record of the other kind started a fresh Bundle.
        case mixedKinds
        /// A row or record left as an `unreadable_` object: it can't be decompressed or validated, or its one-record
        /// Bundle still failed.
        case unreadable
        /// A Bundle failed to validate, so its records were re-packed one per Bundle.
        case bundleValidation
        /// A row or record of another subject was removed without an upload.
        case otherSubject
        /// Grove refused to retract a deletion, which left as an `unreadable_` object.
        case retractionRefused
    }

    private static let logger = Logger(category: .init("HealthUploadIntegrity"))

    let kind: Kind
    /// The chunk's sample type; every chunk holds one.
    let sampleType: String
    /// The chunk's rows this kind handled.
    let rowCount: Int

    /// The default sink.
    static func log(_ event: Self) {
        logger.error("\(event.kind.rawValue): \(event.rowCount) rows of \(event.sampleType)")
    }

    /// Reports `tally` to `sink`, once per kind with a nonzero count, in ``Kind`` order.
    static func report(
        _ tally: [Kind: Int],
        sampleType: String,
        to sink: (Self) -> Void
    ) {
        for kind in Kind.allCases {
            if let rowCount = tally[kind], rowCount > 0 {
                sink(Self(kind: kind, sampleType: sampleType, rowCount: rowCount))
            }
        }
    }
}
