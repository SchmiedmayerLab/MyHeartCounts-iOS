//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation


extension StatsStore {
    /// Determines which stored sources participate independently of the requested sum/minimum/maximum/average.
    enum SourcePolicy: Hashable, Sendable {
        /// Merge when the metric and metadata permit it; otherwise select a preferred source and report the fallback.
        case automatic
        case only(StatsDocument.SourceID)
        /// Prefer these sources in order, then HealthKit and remaining source IDs in lexical order. Fill uncovered buckets.
        case preferred([StatsDocument.SourceID])
        /// Require competing contributions to be mergeable; incompatible overlaps throw instead of falling back.
        case mergeCompatible
    }


    enum Diagnostic: Hashable, Sendable {
        case invalidDocumentCount(Int)
        case malformedEntryCount(Int)
        case preferredSourceFallback(timeRange: Range<Date>, reason: String)
        case approximateAverage(timeRange: Range<Date>)
        /// Boundary contributions were approximated because their distribution within stored buckets is unknown.
        case approximateInterval(timeRange: Range<Date>)
        /// Original buckets were retained because the requested interval would split them.
        case unalignedInterval
        /// A stored bucket extends beyond the requested range; its exact sub-bucket values are unavailable.
        case partialBucket(timeRange: Range<Date>)
    }
}
