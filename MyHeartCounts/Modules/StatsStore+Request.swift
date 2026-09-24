//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import MyHeartCountsShared
import SpeziFoundation
import SpeziHealthKit
import SpeziHealthKitUI


extension StatsStore {
    /// A reusable, value-semantic description of a stats query, independent of SwiftUI and account state.
    struct Request<Element: Sendable>: Hashable, Sendable {
        let metricId: HealthKitStatsCalculator.MetricID
        let timeRange: Range<Date>
        private let processor: any MyHeartCountsShared.ValueTransformer<[StatsDocument], Processor.Output<Element>>

        init(
            metricId: HealthKitStatsCalculator.MetricID,
            timeRange: Range<Date>,
            processor: some MyHeartCountsShared.ValueTransformer<[StatsDocument], Processor.Output<Element>>
        ) {
            self.metricId = metricId
            self.timeRange = timeRange
            self.processor = processor
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.metricId == rhs.metricId && lhs.timeRange == rhs.timeRange && lhs.processor.isEqual(rhs.processor)
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(metricId)
            hasher.combine(timeRange)
            processor.hash(into: &hasher)
        }

        func process(_ documents: [StatsDocument]) throws -> Processor.Output<Element> {
            try processor.transform(documents)
        }

        /// Include adjacent months because the writer may have used a different time zone.
        func monthDocumentIdBounds(calendar: Calendar = .current, now: Date = .now) -> ClosedRange<String>? {
            func monthId(for date: Date, offset: Int) -> String? {
                guard let date = calendar.date(byAdding: .month, value: offset, to: date) else {
                    return nil
                }
                let components = calendar.dateComponents([.year, .month], from: date)
                guard let year = components.year, let month = components.month else {
                    return nil
                }
                return String(format: "%04d-%02d", year, month)
            }
            guard !timeRange.isEmpty,
                  let lower = monthId(for: timeRange.lowerBound, offset: -1),
                  let upper = monthId(for: min(timeRange.upperBound, now), offset: 1),
                  lower <= upper else {
                return nil
            }
            return lower...upper
        }
    }
}


extension StatsStore.Request where Element == QuantitySample {
    private struct QuantityProcessor: MyHeartCountsShared.ValueTransformer {
        let metric: HealthStatsMetric
        let timeRange: Range<Date>
        let aggregationKind: StatisticsAggregationOption
        let sourcePolicy: StatsStore.SourcePolicy
        let interval: StatsStore.AggregationInterval?

        func transform(_ documents: [StatsDocument]) throws -> StatsStore.Processor.Output<QuantitySample> {
            try StatsStore.Processor.quantity(
                documents: documents,
                metric: metric,
                timeRange: timeRange,
                aggregationKind: aggregationKind,
                sourcePolicy: sourcePolicy,
                interval: interval
            )
        }
    }

    /// Query quantity statistics, optionally reducing them before their weights are projected away.
    static func quantity(
        metric: HealthStatsMetric,
        timeRange: HealthKitQueryTimeRange,
        aggregationKind: StatisticsAggregationOption,
        sourcePolicy: StatsStore.SourcePolicy = .automatic,
        interval: StatsStore.AggregationInterval? = nil
    ) -> Self {
        let range = timeRange.range
        return Self(
            metricId: metric.id,
            timeRange: range,
            processor: QuantityProcessor(
                metric: metric, timeRange: range, aggregationKind: aggregationKind, sourcePolicy: sourcePolicy, interval: interval
            )
        )
    }
}


extension StatsStore.Request where Element == SleepSessionStatsSample {
    private struct SleepProcessor: MyHeartCountsShared.ValueTransformer {
        let timeRange: Range<Date>
        let sourcePolicy: StatsStore.SourcePolicy

        func transform(_ documents: [StatsDocument]) throws -> StatsStore.Processor.Output<SleepSessionStatsSample> {
            try StatsStore.Processor.sleepSessions(documents: documents, timeRange: timeRange, sourcePolicy: sourcePolicy)
        }
    }

    static func sleepSessions(in timeRange: HealthKitQueryTimeRange, sourcePolicy: StatsStore.SourcePolicy = .automatic) -> Self {
        let range = timeRange.range
        return Self(metricId: .sleep, timeRange: range, processor: SleepProcessor(timeRange: range, sourcePolicy: sourcePolicy))
    }
}


extension StatsStore.Request where Element == BloodPressureStatsSample {
    private struct BloodPressureProcessor: MyHeartCountsShared.ValueTransformer {
        let timeRange: Range<Date>
        let sourcePolicy: StatsStore.SourcePolicy

        func transform(_ documents: [StatsDocument]) throws -> StatsStore.Processor.Output<BloodPressureStatsSample> {
            try StatsStore.Processor.bloodPressure(documents: documents, timeRange: timeRange, sourcePolicy: sourcePolicy)
        }
    }

    static func bloodPressure(in timeRange: HealthKitQueryTimeRange, sourcePolicy: StatsStore.SourcePolicy = .automatic) -> Self {
        let range = timeRange.range
        return Self(metricId: .bloodPressure, timeRange: range, processor: BloodPressureProcessor(timeRange: range, sourcePolicy: sourcePolicy))
    }
}
