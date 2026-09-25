//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import GroveHealthKitUI


/// How a collection of quantity samples should be aggregated into a collection of aggregated quantity samples
struct QuantitySamplesAggregationStrategy {
    /// The operation that should be used to aggregate a subset of the samples
    let kind: StatisticsAggregationOption
    /// The time interval, for which a subset of the input samples should be turned into an aggregated sample
    let interval: HealthKitStatisticsQuery.AggregationInterval
}
