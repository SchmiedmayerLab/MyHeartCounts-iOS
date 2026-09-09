//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import SpeziHealthKit
import SpeziHealthKitUI


extension StatsStore {
    /// Calendar intervals are applied before projecting aggregates into display samples, preserving available average weights.
    /// The anchor defines the alignment and can precede or follow the requested data.
    struct AggregationInterval: Hashable, Sendable {
        enum AlignmentPolicy: Hashable, Sendable {
            /// Keep original buckets when the requested boundaries cannot be represented exactly.
            case preserveBuckets
            /// Fail rather than returning values at another resolution or approximating boundary contributions.
            case requireExact
            /// Allow diagnosed approximation at boundaries, without subdividing into a finer resolution.
            case approximate
        }

        let interval: HealthKitStatisticsQuery.AggregationInterval
        let anchor: Date
        let calendar: Calendar
        let alignmentPolicy: AlignmentPolicy

        init(
            interval: HealthKitStatisticsQuery.AggregationInterval,
            anchor: Date,
            calendar: Calendar,
            alignmentPolicy: AlignmentPolicy = .preserveBuckets
        ) {
            self.interval = interval
            self.anchor = anchor
            self.calendar = calendar
            self.alignmentPolicy = alignmentPolicy
        }

        /// Locate nearby boundaries in logarithmic time, even for a decades-old hourly anchor.
        func ranges(covering range: Range<Date>) throws -> [Range<Date>] {
            guard try boundary(at: 1) > anchor else {
                throw Processor.Error.invalidAggregationInterval
            }
            var index = try index(containing: range.lowerBound)
            var start = try boundary(at: index)
            var result: [Range<Date>] = []
            while start < range.upperBound {
                guard result.count < 100_000, index < Int.max else {
                    throw Processor.Error.invalidAggregationInterval
                }
                index += 1
                let end = try boundary(at: index)
                guard end > start else {
                    throw Processor.Error.invalidAggregationInterval
                }
                result.append(start..<end)
                start = end
            }
            return result
        }

        private func index(containing date: Date) throws -> Int {
            var lower = 0
            var upper = 0
            if date >= anchor {
                upper = 1
                while try boundary(at: upper) <= date {
                    lower = upper
                    upper = try doubled(upper)
                }
            } else {
                lower = -1
                while try boundary(at: lower) > date {
                    upper = lower
                    lower = try doubled(lower)
                }
            }
            while upper - lower > 1 {
                let middle = lower + (upper - lower) / 2
                if try boundary(at: middle) <= date {
                    lower = middle
                } else {
                    upper = middle
                }
            }
            return lower
        }

        private func doubled(_ value: Int) throws -> Int {
            let result = value.multipliedReportingOverflow(by: 2)
            guard !result.overflow else {
                throw Processor.Error.invalidAggregationInterval
            }
            return result.partialValue
        }

        private func boundary(at index: Int) throws -> Date {
            var components = interval.intervalComponents
            for component: Calendar.Component in [.year, .quarter, .month, .weekOfYear, .weekOfMonth, .day, .hour, .minute, .second, .nanosecond] {
                guard let amount = components.value(for: component) else {
                    continue
                }
                let result = amount.multipliedReportingOverflow(by: index)
                guard amount >= 0, !result.overflow else {
                    throw Processor.Error.invalidAggregationInterval
                }
                components.setValue(result.partialValue, for: component)
            }
            guard let date = calendar.date(byAdding: components, to: anchor) else {
                throw Processor.Error.invalidAggregationInterval
            }
            return date
        }
    }
}
