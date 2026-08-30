//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFoundation
import GroveHealthKit
import GroveHealthKitUI
import HealthKit
import SwiftUI


/// How a collection of quantity samples should be aggregated into a collection of aggregated quantity samples
struct QuantitySamplesAggregationStrategy {
    /// The operation that should be used to aggregate a subset of the samples
    let kind: StatisticsAggregationOption
    /// The time interval, for which a subset of the input samples should be turned into an aggregated sample
    let interval: HealthKitStatisticsQuery.AggregationInterval
}


enum QuantitySamplesQueryingViewAggregationMode { // swiftlint:disable:this type_name
    /// the individual samples should be fetched and returned as-is
    case none
    /// we're only interested in the most recent sample. no additional processing should happen
    case mostRecentSample
    /// the individual samples should be processed into aggregated samples, using a specific kind and over the specified interval
    case aggregate(QuantitySamplesAggregationStrategy)
}


extension HealthKitStatisticsQuery {
    init(
        _ sampleType: SampleType<HKQuantitySample>,
        aggregatedBy: StatisticsAggregationOption,
        over aggregationInterval: AggregationInterval,
        timeRange: HealthKitQueryTimeRange,
        filter: NSPredicate? = nil
    ) {
        switch aggregatedBy {
        case .sum:
            self.init(sampleType, aggregatedBy: [.sum], over: aggregationInterval, timeRange: timeRange, filter: filter)
        case .avg:
            self.init(sampleType, aggregatedBy: [.average], over: aggregationInterval, timeRange: timeRange, filter: filter)
        case .min:
            self.init(sampleType, aggregatedBy: [.min], over: aggregationInterval, timeRange: timeRange, filter: filter)
        case .max:
            self.init(sampleType, aggregatedBy: [.max], over: aggregationInterval, timeRange: timeRange, filter: filter)
        }
    }
}
