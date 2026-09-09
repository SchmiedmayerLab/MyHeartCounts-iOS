//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import SpeziHealthKitUI


extension StatsStore.Processor {
    private struct IntervalGroups {
        var values: [[Value]]
        var approximatedIndices: Set<Int> = []
    }

    static func reduced(
        _ values: [Value], input: Input, interval: StatsStore.AggregationInterval, diagnostics: inout [StatsStore.Diagnostic]
    ) throws -> [Value] {
        guard !values.isEmpty else {
            return []
        }
        let lower = Swift.max(values.map(\.range.lowerBound).min() ?? input.timeRange.lowerBound, input.timeRange.lowerBound)
        let upper = Swift.min(values.map(\.range.upperBound).max() ?? input.timeRange.upperBound, input.timeRange.upperBound)
        let end = Date(timeIntervalSinceReferenceDate: upper.timeIntervalSinceReferenceDate.nextUp)
        let ranges = try interval.ranges(covering: lower..<end).filter { overlaps($0, input.timeRange) }
        let groups: IntervalGroups
        if let exact = grouped(values, into: ranges, timeRange: input.timeRange) {
            groups = exact
        } else {
            if interval.alignmentPolicy == .requireExact || input.sourcePolicy == .mergeCompatible {
                throw Error.unalignedAggregationInterval
            }
            guard interval.alignmentPolicy == .approximate,
                  let approximate = grouped(values, into: ranges, timeRange: input.timeRange, approximating: input.aggregationKind) else {
                diagnostics.append(.unalignedInterval)
                return values
            }
            groups = approximate
        }
        return try ranges.indices.compactMap { index in
            let range = ranges[index]
            let contained = groups.values[index]
            guard !contained.isEmpty else {
                return nil
            }
            if groups.approximatedIndices.contains(index) {
                diagnostics.append(.approximateInterval(timeRange: range))
            }
            var result = contained[0]
            result.range = range
            result.sources = Set(contained.flatMap(\.sources))
            result.average = combinedAverage(contained)
            result.amount = try reducedAmount(contained, average: result.average, range: range, input: input, diagnostics: &diagnostics)
            return result
        }
    }

    /// Both inputs are chronological. A crossing bucket visits only the additional boundaries it overlaps.
    private static func grouped(
        _ values: [Value], into ranges: [Range<Date>], timeRange: Range<Date>, approximating kind: StatisticsAggregationOption? = nil
    ) -> IntervalGroups? {
        var result = IntervalGroups(values: Array(repeating: [], count: ranges.count))
        var index = 0
        for value in values {
            let start = Swift.max(value.range.lowerBound, timeRange.lowerBound)
            let end = Swift.min(value.range.upperBound, timeRange.upperBound)
            while index < ranges.count && start >= ranges[index].upperBound {
                index += 1
            }
            guard index < ranges.count, start >= ranges[index].lowerBound else {
                return nil
            }
            if end <= ranges[index].upperBound, value.range == start..<end {
                result.values[index].append(value)
                continue
            }
            guard let kind else {
                return nil
            }
            var target = index
            while target < ranges.count && ranges[target].lowerBound < end {
                // Do not invent a finer resolution, even when approximation was explicitly requested.
                guard value.range.upperBound.timeIntervalSince(value.range.lowerBound)
                    <= ranges[target].upperBound.timeIntervalSince(ranges[target].lowerBound) else {
                    return nil
                }
                let bounds = Swift.max(start, ranges[target].lowerBound)..<Swift.min(end, ranges[target].upperBound)
                result.values[target].append(fragment(value, in: bounds, using: kind))
                result.approximatedIndices.insert(target)
                target += 1
            }
        }
        return result
    }

    private static func fragment(_ value: Value, in range: Range<Date>, using kind: StatisticsAggregationOption) -> Value {
        var result = value
        result.range = range
        if kind == .sum {
            result.amount *= range.upperBound.timeIntervalSince(range.lowerBound) / value.range.upperBound.timeIntervalSince(value.range.lowerBound)
        }
        // Neither a partial bucket's exact mean nor its weights can be recovered from whole-bucket aggregates.
        // Averages and extrema retain the bucket's value as an explicitly diagnosed approximation.
        result.average = nil
        return result
    }

    private static func reducedAmount(
        _ values: [Value], average: StatsDocument.Average?, range: Range<Date>, input: Input, diagnostics: inout [StatsStore.Diagnostic]
    ) throws -> Double {
        switch input.aggregationKind {
        case .sum:
            return values.reduce(0) { $0 + $1.amount }
        case .min:
            return values.reduce(values[0].amount) { Swift.min($0, $1.amount) }
        case .max:
            return values.reduce(values[0].amount) { Swift.max($0, $1.amount) }
        case .avg:
            if let average {
                return average.numerator / average.denominator
            }
            if values.count > 1 && values.contains(where: { !$0.range.isEmpty }) {
                if input.sourcePolicy == .mergeCompatible {
                    throw Error.incompatibleSources(timeRange: range, reason: "Missing compatible average weights")
                }
                diagnostics.append(.approximateAverage(timeRange: range))
            }
            return values.reduce(0) { $0 + $1.amount } / Double(values.count)
        }
    }
}
