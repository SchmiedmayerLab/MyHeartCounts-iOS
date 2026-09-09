//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import HealthKit
import MyHeartCountsShared
import SpeziHealthKit
import SpeziHealthKitUI


extension StatsStore {
    /// Pure processing shared by one-shot reads, live subscriptions, and SwiftUI queries.
    enum Processor {
        struct Value {
            var range: Range<Date>
            var amount: Double
            var secondaryAmount: Double?
            var average: StatsDocument.Average?
            var sources: Set<StatsDocument.SourceID>
        }

        private struct Selection {
            var values: [Value] = []
            var bucketIndices: [Range<Date>: Int] = [:]
            var maximumBucketEnd: Date?
            var hasObservations = false

            mutating func append(_ value: Value) {
                if value.range.isEmpty {
                    hasObservations = true
                } else {
                    bucketIndices[value.range] = values.count
                    maximumBucketEnd = Swift.max(maximumBucketEnd ?? value.range.upperBound, value.range.upperBound)
                }
                values.append(value)
            }
        }

        struct Input {
            let metricID: String
            let timeRange: Range<Date>
            let sourcePolicy: SourcePolicy
            let unit: HKUnit
            let aggregationKind: StatisticsAggregationOption
        }

        static func quantity(
            documents: [StatsDocument],
            metric: HealthStatsMetric,
            timeRange: Range<Date>,
            aggregationKind: StatisticsAggregationOption,
            sourcePolicy: SourcePolicy = .automatic,
            interval: AggregationInterval? = nil
        ) throws -> Output<QuantitySample> {
            let input = Input(
                metricID: metric.id.rawValue,
                timeRange: timeRange,
                sourcePolicy: sourcePolicy,
                unit: metric.sampleType.canonicalUnit,
                aggregationKind: aggregationKind
            )
            var diagnostics: [Diagnostic] = []
            var values = try selectedValues(documents: documents, input: input, diagnostics: &diagnostics)
            if let interval {
                values = try reduced(values, input: input, interval: interval, diagnostics: &diagnostics)
            }
            return Output(
                elements: values.map {
                    QuantitySample(
                        id: UUID(),
                        sampleType: .healthKit(metric.sampleType),
                        unit: input.unit,
                        value: $0.amount,
                        startDate: $0.range.lowerBound,
                        endDate: $0.range.upperBound
                    )
                },
                diagnostics: diagnostics,
                contributingSourceIDs: Set(values.flatMap(\.sources))
            )
        }

        static func sleepSessions(
            documents: [StatsDocument], timeRange: Range<Date>, sourcePolicy: SourcePolicy = .automatic
        ) throws -> Output<SleepSessionStatsSample> {
            let input = Input(metricID: "sleep", timeRange: timeRange, sourcePolicy: sourcePolicy, unit: .hour(), aggregationKind: .sum)
            var diagnostics: [Diagnostic] = []
            let values = try selectedValues(documents: documents, input: input, diagnostics: &diagnostics)
            return Output(
                elements: values.sorted { $0.range.upperBound < $1.range.upperBound }.map {
                    SleepSessionStatsSample(timeRange: $0.range, hoursAsleep: $0.amount)
                },
                diagnostics: diagnostics,
                contributingSourceIDs: Set(values.flatMap(\.sources))
            )
        }

        static func bloodPressure(
            documents: [StatsDocument], timeRange: Range<Date>, sourcePolicy: SourcePolicy = .automatic
        ) throws -> Output<BloodPressureStatsSample> {
            let input = Input(
                metricID: "blood-pressure",
                timeRange: timeRange,
                sourcePolicy: sourcePolicy,
                unit: .millimeterOfMercury(),
                aggregationKind: .avg
            )
            var diagnostics: [Diagnostic] = []
            let values = try selectedValues(documents: documents, input: input, diagnostics: &diagnostics)
            return Output(
                elements: values.compactMap { value in
                    value.secondaryAmount.map { BloodPressureStatsSample(date: value.range.lowerBound, systolic: value.amount, diastolic: $0) }
                },
                diagnostics: diagnostics,
                contributingSourceIDs: Set(values.flatMap(\.sources))
            )
        }
    }
}


// MARK: Validation and Normalization

extension StatsStore.Processor {
    private static func values(documents: [StatsDocument], input: Input, diagnostics: inout [StatsStore.Diagnostic]) -> [Value] {
        guard !input.timeRange.isEmpty else {
            return []
        }
        var values: [Value] = []
        var invalidDocuments = 0
        var malformedEntries = 0
        for document in documents {
            guard document.version == 0, document.metric == input.metricID else {
                invalidDocuments += 1
                continue
            }
            malformedEntries += document.malformedEntryCount
            for (source, entries) in document.entriesBySourceId {
                if case .only(let requiredSource) = input.sourcePolicy, source != requiredSource {
                    continue
                }
                for entry in entries {
                    guard let range = entry.timeRange, let value = value(entry, source: source, input: input) else {
                        malformedEntries += 1
                        continue
                    }
                    guard overlaps(range, input.timeRange) else {
                        continue
                    }
                    values.append(value)
                }
            }
        }
        if invalidDocuments > 0 {
            diagnostics.append(.invalidDocumentCount(invalidDocuments))
        }
        if malformedEntries > 0 {
            diagnostics.append(.malformedEntryCount(malformedEntries))
        }
        return sorted(values, policy: input.sourcePolicy)
    }

    private static func sorted(_ values: [Value], policy: StatsStore.SourcePolicy) -> [Value] {
        let sources = sourceOrder(Set(values.flatMap(\.sources)), policy: policy)
        return values.sorted { lhs, rhs in
            let leftRank = sources.firstIndex { lhs.sources.contains($0) } ?? sources.count
            let rightRank = sources.firstIndex { rhs.sources.contains($0) } ?? sources.count
            if leftRank != rightRank {
                return leftRank < rightRank
            }
            if lhs.range.lowerBound != rhs.range.lowerBound {
                return lhs.range.lowerBound < rhs.range.lowerBound
            }
            if lhs.range.upperBound != rhs.range.upperBound {
                return lhs.range.upperBound < rhs.range.upperBound
            }
            return lhs.amount < rhs.amount
        }
    }

    private static func value(_ entry: StatsDocument.Entry, source: StatsDocument.SourceID, input: Input) -> Value? {
        guard let range = entry.timeRange, let unit = HKUnit.parse(entry.unit),
              HKQuantity(unit: unit, doubleValue: 0).is(compatibleWith: input.unit) else {
            return nil
        }
        let amount = if input.metricID == "blood-pressure" {
            entry.systolic
        } else if let value = entry.value {
            value
        } else {
            switch input.aggregationKind {
            case .sum: entry.sum
            case .avg: entry.avg
            case .min: entry.min
            case .max: entry.max
            }
        }
        guard let amount, amount.isFinite else {
            return nil
        }
        if input.metricID == "blood-pressure", entry.diastolic?.isFinite != true {
            return nil
        }
        func converted(_ amount: Double) -> Double {
            HKQuantity(unit: unit, doubleValue: amount).doubleValue(for: input.unit)
        }
        let average = entry.average.flatMap { average -> StatsDocument.Average? in
            guard average.isValid, let mean = entry.avg, mean.isFinite,
                  abs(average.numerator / average.denominator - mean) <= Swift.max(1, abs(mean)) * 1e-9 else {
                return nil
            }
            // Convert the mean, not the numerator: this also handles unit conversions with an offset.
            return StatsDocument.Average(
                numerator: converted(average.numerator / average.denominator) * average.denominator,
                denominator: average.denominator,
                weighting: average.weighting
            )
        }
        return Value(
            range: range,
            amount: converted(amount),
            secondaryAmount: entry.diastolic.map(converted),
            average: average,
            sources: [source]
        )
    }

    private static func sourceOrder(_ sources: Set<StatsDocument.SourceID>, policy: StatsStore.SourcePolicy) -> [StatsDocument.SourceID] {
        let preferred: [StatsDocument.SourceID] = if case .preferred(let sources) = policy { sources } else { [] }
        var result: [StatsDocument.SourceID] = []
        for source in preferred + ["com.apple.HealthKit"] + sources.sorted() where !result.contains(source) {
            result.append(source)
        }
        return result
    }

    static func overlaps(_ lhs: Range<Date>, _ rhs: Range<Date>) -> Bool {
        if lhs.isEmpty {
            return rhs.isEmpty ? lhs.lowerBound == rhs.lowerBound : rhs.contains(lhs.lowerBound)
        }
        if rhs.isEmpty {
            return lhs.contains(rhs.lowerBound)
        }
        return lhs.overlaps(rhs)
    }
}


// MARK: Source Selection

extension StatsStore.Processor {
    private static func selectedValues(documents: [StatsDocument], input: Input, diagnostics: inout [StatsStore.Diagnostic]) throws -> [Value] {
        var selected = Selection()
        for value in values(documents: documents, input: input, diagnostics: &diagnostics) {
            let conflicts = conflictingIndices(for: value, in: selected)
            if conflicts.isEmpty {
                selected.append(value)
            } else if conflicts.count == 1, let index = conflicts.first,
                      let merged = mergedSources(selected.values[index], value, input: input) {
                selected.values[index] = merged
            } else {
                try fallback(value.range, input: input, diagnostics: &diagnostics)
            }
        }
        for value in selected.values where !value.range.isEmpty
            && (value.range.lowerBound < input.timeRange.lowerBound || value.range.upperBound > input.timeRange.upperBound) {
            diagnostics.append(.partialBucket(timeRange: value.range))
        }
        return selected.values.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    private static func conflictingIndices(for value: Value, in selection: Selection) -> [Int] {
        if !selection.hasObservations, !value.range.isEmpty {
            if selection.maximumBucketEnd.map({ value.range.lowerBound >= $0 }) ?? true {
                return []
            }
            // Selected buckets never overlap. An exact match therefore identifies the only possible conflict.
            if let index = selection.bucketIndices[value.range] {
                return [index]
            }
        }
        return selection.values.indices.filter { index in
            let existing = selection.values[index]
            if value.range.isEmpty && existing.range.isEmpty {
                // Different instants fill gaps. Only simultaneous readings compete across sources.
                return existing.sources != value.sources && existing.range.lowerBound == value.range.lowerBound
            }
            return overlaps(existing.range, value.range)
        }
    }

    private static func mergedSources(_ lhs: Value, _ rhs: Value, input: Input) -> Value? {
        guard input.sourcePolicy == .automatic || input.sourcePolicy == .mergeCompatible,
              input.metricID == "heart-rate", !lhs.range.isEmpty, lhs.range == rhs.range,
              lhs.range.lowerBound >= input.timeRange.lowerBound, lhs.range.upperBound <= input.timeRange.upperBound else {
            return nil
        }
        var result = lhs
        switch input.aggregationKind {
        case .min:
            result.amount = Swift.min(lhs.amount, rhs.amount)
        case .max:
            result.amount = Swift.max(lhs.amount, rhs.amount)
        case .avg:
            guard let average = combinedAverage([lhs, rhs]) else {
                return nil
            }
            result.average = average
            result.amount = average.numerator / average.denominator
        case .sum:
            return nil
        }
        result.sources.formUnion(rhs.sources)
        return result
    }

    private static func fallback(_ range: Range<Date>, input: Input, diagnostics: inout [StatsStore.Diagnostic]) throws {
        let reason = "Competing readings, overlapping totals, unaligned buckets, or incompatible average weights"
        if input.sourcePolicy == .mergeCompatible {
            throw Error.incompatibleSources(timeRange: range, reason: reason)
        }
        diagnostics.append(.preferredSourceFallback(timeRange: range, reason: reason))
    }

    static func combinedAverage(_ values: [Value]) -> StatsDocument.Average? {
        guard let weighting = values.first?.average?.weighting,
              values.allSatisfy({ $0.average?.weighting == weighting }) else {
            return nil
        }
        let result = StatsDocument.Average(
            numerator: values.reduce(0) { $0 + ($1.average?.numerator ?? 0) },
            denominator: values.reduce(0) { $0 + ($1.average?.denominator ?? 0) },
            weighting: weighting
        )
        return result.isValid ? result : nil
    }
}


extension StatsStore.Processor {
    struct Output<Element: Sendable>: Sendable {
        let elements: [Element]
        var diagnostics: [StatsStore.Diagnostic]
        let contributingSourceIDs: Set<StatsDocument.SourceID>
    }


    enum Error: Swift.Error, Equatable {
        case incompatibleSources(timeRange: Range<Date>, reason: String)
        case invalidAggregationInterval
        case unalignedAggregationInterval
    }
}
