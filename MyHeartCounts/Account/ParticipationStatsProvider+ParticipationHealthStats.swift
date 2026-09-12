//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import HealthKit
import SpeziHealthKit
import SpeziHealthKitUI


extension ParticipationStatsProvider {
    struct HealthSnapshots: Sendable {
        private typealias Provider = ParticipationStatsProvider

        var steps: StatsStore.Snapshot<QuantitySample>?
        var energy: StatsStore.Snapshot<QuantitySample>?
        var distance: StatsStore.Snapshot<QuantitySample>?
        var exercise: StatsStore.Snapshot<QuantitySample>?
        var flights: StatsStore.Snapshot<QuantitySample>?
        var heartRate: StatsStore.Snapshot<QuantitySample>?
        var maxHeartRate: StatsStore.Snapshot<QuantitySample>?
        var restingHeartRate: StatsStore.Snapshot<QuantitySample>?
        var sleep: StatsStore.Snapshot<SleepSessionStatsSample>?
        var workouts: StatsStore.Snapshot<WorkoutStatsSample>?
        var ecgs: StatsStore.Snapshot<ElectrocardiogramStatsSample>?

        @MainActor
        func healthStats(in range: Range<Date>) -> ParticipationHealthStats {
            let stepSamples = Provider.samples(steps)
            let workoutSamples = Provider.samples(workouts)?.filter { $0.endDate < range.upperBound }
            let maximumHeartRate = Provider.samples(maxHeartRate)?.map { $0.value(as: .count() / .minute()) }.max()
            return ParticipationHealthStats(
                totalSteps: sum(steps, unit: .count()).flatMap { Provider.integerValue($0) },
                totalActiveEnergyKcal: sum(energy, unit: .kilocalorie()),
                totalDistanceWalkingRunning: sum(distance, unit: .meter()).map { .init(value: $0, unit: .meters) },
                totalExerciseTime: sum(exercise, unit: .second()).map { .init(value: $0, unit: .seconds) },
                totalFlightsClimbed: sum(flights, unit: .count()).flatMap { Provider.integerValue($0) },
                totalHeartbeats: Provider.samples(heartRate)
                    .flatMap { Provider.estimatedHeartbeats($0, in: range) }
                    .flatMap { Provider.integerValue($0, rounding: .toNearestOrAwayFromZero) },
                totalSleepTime: Provider.samples(sleep).flatMap { Provider.sleepSeconds($0, in: range) }.map { .init(value: $0, unit: .seconds) },
                workoutInfo: workoutSamples.map {
                    .init(numWorkouts: $0.count, totalDuration: .init(value: $0.reduce(0) { $0 + $1.duration }, unit: .seconds))
                },
                highlights: ParticipationHealthStats.HealthHighlights(
                    bestDailySteps: stepSamples.flatMap(Provider.bestStepDay),
                    longestWorkout: workoutSamples.flatMap(Provider.longestWorkout),
                    maxHeartRateBPM: maximumHeartRate.flatMap { Provider.integerValue($0, rounding: .toNearestOrAwayFromZero) },
                    avgRestingHeartRateBPM: Provider.samples(restingHeartRate).flatMap(Provider.meanRestingHeartRate)
                )
            )
        }

        @MainActor
        func ecgCount(before date: Date) -> Int? {
            Provider.samples(ecgs)?.filter { $0.endDate < date }.count
        }

        @MainActor
        private func sum(_ snapshot: StatsStore.Snapshot<QuantitySample>?, unit: HKUnit) -> Double? {
            guard let samples = Provider.samples(snapshot) else {
                return nil
            }
            let value = samples.reduce(0) { $0 + $1.value(as: unit) }
            return value.isFinite ? value : nil
        }
    }

    struct QuantityQuery: Sendable {
        let metric: HealthStatsMetric
        let aggregation: StatisticsAggregationOption
        let daily: Bool
        let keyPath: any WritableKeyPath<HealthSnapshots, StatsStore.Snapshot<QuantitySample>?> & Sendable
    }

    static var quantityQueries: [QuantityQuery] {
        [
            .init(metric: .steps, aggregation: .sum, daily: true, keyPath: \.steps),
            .init(metric: .activeEnergy, aggregation: .sum, daily: true, keyPath: \.energy),
            .init(metric: .walkingRunningDistance, aggregation: .sum, daily: true, keyPath: \.distance),
            .init(metric: .exerciseTime, aggregation: .sum, daily: true, keyPath: \.exercise),
            .init(metric: .flightsClimbed, aggregation: .sum, daily: true, keyPath: \.flights),
            .init(metric: .heartRate, aggregation: .avg, daily: false, keyPath: \.heartRate),
            .init(metric: .heartRate, aggregation: .max, daily: true, keyPath: \.maxHeartRate),
            .init(metric: .restingHeartRate, aggregation: .avg, daily: false, keyPath: \.restingHeartRate)
        ]
    }

    // swiftlint:disable:next discouraged_optional_collection
    static func samples<Element>(_ snapshot: StatsStore.Snapshot<Element>?) -> [Element]? {
        snapshot.flatMap { isUsable($0) ? $0.elements : nil }
    }
}


extension ParticipationStatsProvider {
    static func quantityRequest(
        _ metric: HealthStatsMetric,
        in range: Range<Date>,
        aggregation: StatisticsAggregationOption,
        daily: Bool = true,
        calendar: Calendar = .current
    ) -> StatsStore.Request<QuantitySample> {
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: range.upperBound)) ?? range.upperBound
        let upperBound = daily && !range.isEmpty && range.upperBound != calendar.startOfDay(for: range.upperBound)
            ? endOfDay : range.upperBound
        return .quantity(
            metric: metric,
            timeRange: .init(range.lowerBound..<upperBound),
            aggregationKind: aggregation,
            sourcePolicy: .automatic,
            // Include today's entire stored buckets: their values already reflect only samples recorded so far.
            // Explicitly approximate timezone-shifted day boundaries, rejecting any unaligned fallback below.
            interval: daily ? .init(
                interval: .day,
                anchor: calendar.startOfDay(for: range.lowerBound),
                calendar: calendar,
                alignmentPolicy: .approximate
            ) : nil
        )
    }

    static func isUsable<Element>(_ snapshot: StatsStore.Snapshot<Element>) -> Bool {
        !snapshot.elements.isEmpty && !snapshot.diagnostics.contains { diagnostic in
            switch diagnostic {
            case .invalidDocumentCount, .malformedEntryCount, .unalignedInterval: true
            default: false
            }
        }
    }
}


extension ParticipationStatsProvider {
    /// Remote values and reductions can exceed the integer range or become non-finite.
    static func integerValue(_ value: Double, rounding rule: FloatingPointRoundingRule = .towardZero) -> Int? {
        Int(exactly: value.rounded(rule))
    }

    static func bestStepDay(_ samples: [QuantitySample]) -> ParticipationHealthStats.HealthHighlights.Entry<Int>? {
        samples.filter { $0.value(as: .count()) > 0 }
            .max { $0.value(as: .count()) < $1.value(as: .count()) }
            .flatMap { sample in
                integerValue(sample.value(as: .count())).map { .init(date: sample.startDate, value: $0) }
            }
    }

    static func longestWorkout(_ workouts: [WorkoutStatsSample]) -> ParticipationHealthStats.LongestWorkoutInfo? {
        workouts.max { $0.duration < $1.duration }.map {
            .init(date: $0.date, activityType: $0.activityType, duration: .init(value: $0.duration, unit: .seconds))
        }
    }

    static func meanRestingHeartRate(_ samples: [QuantitySample]) -> Int? {
        guard !samples.isEmpty, samples.allSatisfy({ $0.timeRange.isEmpty }) else {
            return nil
        }
        // The resting-heart-rate metric stores individual readings, preserving the sample-count denominator.
        let total = samples.reduce(0) { $0 + $1.value(as: .count() / .minute()) }
        return integerValue(total / Double(samples.count), rounding: .toNearestOrAwayFromZero)
    }

    static func estimatedHeartbeats(_ samples: [QuantitySample], in range: Range<Date>) -> Double? {
        guard !samples.isEmpty else {
            return nil
        }
        // Integrate only recorded buckets. Reducing to days first would fill unrecorded hours with a daily mean.
        return samples.reduce(0) { total, sample in
            let seconds = overlapSeconds(sample.timeRange, range)
            return total + sample.value(as: .count() / .minute()) * seconds / 60
        }
    }

    static func sleepSeconds(_ sessions: [SleepSessionStatsSample], in range: Range<Date>) -> Double? {
        guard !sessions.isEmpty else {
            return nil
        }
        return sessions.reduce(0) { total, session in
            let duration = session.timeRange.timeInterval
            guard duration > 0 else {
                return total
            }
            // Session aggregates contain no sleep-stage distribution, so boundary clipping is proportional.
            return total + session.hoursAsleep * 3600 * overlapSeconds(session.timeRange, range) / duration
        }
    }

    private static func overlapSeconds(_ first: Range<Date>, _ second: Range<Date>) -> Double {
        max(0, min(first.upperBound, second.upperBound).timeIntervalSince(max(first.lowerBound, second.lowerBound)))
    }
}
