//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import Spezi
import SpeziHealthKit
import SpeziScheduler
import SpeziStudy


@Observable
final class ParticipationStatsProvider: Module, EnvironmentAccessible, @unchecked Sendable {
    // swiftlint:disable attributes
    @ObservationIgnored @Dependency(HealthKit.self) private var healthKit
    @ObservationIgnored @Dependency(Scheduler.self) private var scheduler
    // swiftlint:enable attributes
    
    nonisolated init() {}
    
    static func enrollmentTimeRange(for enrollment: StudyEnrollment, upTo now: Date) -> Range<Date> {
        let startDate = enrollment.enrollmentDate
        return if startDate < now {
            startDate..<now
        } else {
            now..<now
        }
    }
}


extension ParticipationStatsProvider {
    struct Stats: Sendable {
        let enrollment: EnrollmentStats
        let appEngagement: AppEngagementStats?
        let taskEngagement: TaskEngagementStats
        let health: HealthStats
    }
    
    
    struct EnrollmentStats: Sendable {
        let enrollmentDate: Date
        let numDaysEnrolled: Int
        let numWeeksEnrolled: Int
        let numMonthsEnrolled: Int
        let numYearsEnrolled: Int
    }
    
    struct AppEngagementStats: Sendable {
        /// The user's current streak of opening the app at least once per week.
        let currentLaunchAppStreak: Int
        /// The user's longest recorded streak of opening the app at least once per week.
        let longestLaunchAppStreak: Int
    }
    
    struct TaskEngagementStats: Sendable {
        let totalCompleted: Int
        let questionnairesCompleted: Int
        let articlesRead: Int
        let ecgsRecorded: Int
        let walkRunTestsCompleted: Int
    }
    
    
    struct HealthStats: Sendable {
        struct WorkoutInfo: Sendable {
            let numWorkouts: Int
            let totalDuration: Measurement<UnitDuration>
        }
        
        struct LongestWorkoutInfo: Sendable {
            let date: Date
            let activityType: HKWorkoutActivityType
            let duration: Measurement<UnitDuration>
        }
        
        struct PersonalBests: Sendable {
            struct Entry<Value: Sendable>: Sendable { // swiftlint:disable:this nesting
                let date: Date
                let value: Value
                
                fileprivate func map<NewValue>(_ transform: (Value) -> NewValue) -> Entry<NewValue> {
                    .init(date: date, value: transform(value))
                }
            }
            
            let bestDailySteps: Entry<Int>?
            let longestWorkout: LongestWorkoutInfo?
            let maxHeartRateBPM: Int?
            let avgRestingHeartRateBPM: Int?
        }
        
        let totalSteps: Int?
        let totalActiveEnergyKcal: Double?
        let totalDistanceWalkingRunning: Measurement<UnitLength>?
        let totalExerciseTime: Measurement<UnitDuration>?
        let totalFlightsClimbed: Int?
        let totalHeartbeats: Int?
        let totalSleepTime: Measurement<UnitDuration>?
        let workoutInfo: WorkoutInfo?
        let personalBests: PersonalBests
    }
}


extension ParticipationStatsProvider {
    func computeStats(for enrollment: StudyEnrollment) async -> Stats {
        let now = Date()
        let cal = Calendar.current
        let studyId = enrollment.studyId
        let enrollmentDate = enrollment.enrollmentDate
        let enrollmentTimeRange = if enrollmentDate < now {
            cal.startOfDay(for: enrollmentDate)..<now
        } else {
            // unlikely but let's make sure this does not crash.
            now..<now
        }
        async let taskEngagement = computeTaskEngagementStats(studyId: studyId, enrollmentTimeRange: enrollmentTimeRange)
        async let healthStats = computeHealthStats(for: enrollmentTimeRange)
        return Stats(
            enrollment: EnrollmentStats(
                enrollmentDate: enrollmentDate,
                numDaysEnrolled: cal.countDistinctDays(from: enrollmentDate, to: now),
                numWeeksEnrolled: cal.countDistinctWeeks(from: enrollmentDate, to: now),
                numMonthsEnrolled: cal.countDistinctMonths(from: enrollmentDate, to: now),
                numYearsEnrolled: cal.countDistinctYears(from: enrollmentDate, to: now)
            ),
            appEngagement: computeAppEngagementStats(enrollmentTimeRange: enrollmentTimeRange),
            taskEngagement: await taskEngagement,
            health: await healthStats
        )
    }
    
    nonisolated private func computeAppEngagementStats(enrollmentTimeRange: Range<Date>) -> AppEngagementStats {
        // TODO (we don't have app opening tracking yet...)
        return AppEngagementStats(
            currentLaunchAppStreak: 0,
            longestLaunchAppStreak: 0
        )
    }
    
    @MainActor // required bc of the Scheduler...
    private func computeTaskEngagementStats(
        studyId: UUID,
        enrollmentTimeRange: Range<Date>
    ) async -> TaskEngagementStats {
        // ECGs come from HealthKit rather than from Scheduler outcomes so the count survives a
        // reinstall (HealthKit data persists; the Scheduler's local task-completion store does not).
        async let ecgCount = countECGs(in: enrollmentTimeRange)
        let events: [Event] = (try? scheduler.queryEvents(for: enrollmentTimeRange)) ?? []
        let studyEvents = events.filter { event in
            event.isCompleted && event.task.studyContext?.studyId == studyId
        }
        var perCategory: [Task.Category: Int] = [:]
        for event in studyEvents {
            if let cat = event.task.category {
                perCategory[cat, default: 0] += 1
            }
        }
        let walkRun = (perCategory[.timedWalkingTest] ?? 0) + (perCategory[.timedRunningTest] ?? 0)
        return TaskEngagementStats(
            totalCompleted: studyEvents.count,
            questionnairesCompleted: perCategory[.questionnaire] ?? 0,
            articlesRead: perCategory[.informational] ?? 0,
            ecgsRecorded: (await ecgCount) ?? 0,
            walkRunTestsCompleted: walkRun
        )
    }
}


extension ParticipationStatsProvider {
    // MARK: Health Stats
    
    private func computeHealthStats(for timeRange: Range<Date>) async -> HealthStats {
        async let steps = cumulativeSum(in: timeRange, of: .stepCount).map(Int.init)
        async let energy = cumulativeSum(in: timeRange, of: .activeEnergyBurned)
        async let distance = cumulativeSum(in: timeRange, of: .distanceWalkingRunning)
        async let exerciseMin = cumulativeSum(in: timeRange, of: .appleExerciseTime)
        async let flights = cumulativeSum(in: timeRange, of: .flightsClimbed).map(Int.init)
        async let heartbeats = estimateTotalHeartbeats(in: timeRange)
        async let sleepSec = totalSleepSeconds(in: timeRange)
        async let workoutStats = loadWorkoutStats(in: timeRange)
        async let personalBests = computePersonalBests(in: timeRange)
        return HealthStats(
            totalSteps: await steps,
            totalActiveEnergyKcal: await energy,
            totalDistanceWalkingRunning: (await distance).map { .init(value: $0, unit: .meters) },
            totalExerciseTime: (await exerciseMin).map { .init(value: $0 * 60, unit: .seconds) },
            totalFlightsClimbed: await flights,
            totalHeartbeats: Int(await heartbeats),
            totalSleepTime: (await sleepSec).map { .init(value: $0, unit: .seconds) },
            workoutInfo: await workoutStats,
            personalBests: await personalBests
        )
    }
    
    private func computePersonalBests(in timeRange: Range<Date>) async -> HealthStats.PersonalBests {
        async let bestStepDay = bestDay(in: timeRange, of: .stepCount)?.map { Int($0) }
        async let longestWorkout = longestWorkout(in: timeRange)
        async let maxHR: Double? = discreteStat(
            in: timeRange,
            of: .heartRate,
            option: .max,
            aggregator: { $0.maximumQuantity()?.doubleValue(for: .count() / .minute()) },
            reducer: { $0.max() }
        )
        async let avgRestingHR: Double? = discreteStat(
            in: timeRange,
            of: .restingHeartRate,
            option: .average,
            aggregator: { $0.averageQuantity()?.doubleValue(for: .count() / .minute()) },
            reducer: { $0.isEmpty ? nil : $0.reduce(0, +) / Double($0.count) }
        )
        return HealthStats.PersonalBests(
            bestDailySteps: await bestStepDay,
            longestWorkout: await longestWorkout,
            maxHeartRateBPM: (await maxHR).map { Int($0.rounded()) },
            avgRestingHeartRateBPM: (await avgRestingHR).map { Int($0.rounded()) }
        )
    }
    
    private func cumulativeSum(
        in timeRange: Range<Date>,
        of sampleType: SampleType<HKQuantitySample>,
        using unit: HKUnit? = nil
    ) async -> Double? {
        guard let stats = try? await healthKit.statisticsQuery(
            sampleType,
            aggregatedBy: [.sum],
            over: .year,
            timeRange: .init(timeRange)
        ) else {
            return nil
        }
        let unit = unit ?? sampleType.displayUnit
        return stats.reduce(0) { $0 + ($1.sumQuantity()?.doubleValue(for: unit) ?? 0) }
    }
    
    /// Determines the daily best for a cumulative sample type, e.g. the max total quantity value observed over the course of a single day.
    ///
    /// - parameter timeRange: The time range for which the daily best should be computed
    /// - parameter sampleType: The sample type to operate on
    /// - parameter unit: The `HKUnit` to use when working with samples. Defaults to `sampleType.displayUnit` if `nil`.
    /// - parameter isConsideredBetter: Compares two values (of unit `unit`) to determine if the first one is "better" than the second one.
    ///     Defaults to a greater-than comparison, which results in the function selecting the highest daily sum.
    ///     For a metric where the lowest-possible value is be considered the "daily best", you would pass a lower-than comparison function (i.e., `(<)`).
    private func bestDay(
        in timeRange: Range<Date>,
        of sampleType: SampleType<HKQuantitySample>,
        using unit: HKUnit? = nil,
        isConsideredBetter: (_ fst: Double, _ snd: Double) -> Bool = (>)
    ) async -> HealthStats.PersonalBests.Entry<Double>? {
        guard sampleType.hkSampleType.aggregationStyle == .cumulative else {
            return nil
        }
        let cal = Calendar.current
        assert(timeRange.lowerBound == cal.startOfDay(for: timeRange.lowerBound))
        guard let stats = try? await healthKit.statisticsQuery(
            sampleType,
            aggregatedBy: [.sum],
            over: .day,
            timeRange: .init(timeRange)
        ) else {
            return nil
        }
        let unit = unit ?? sampleType.displayUnit
        return stats
            .compactMap { stat -> HealthStats.PersonalBests.Entry<Double>? in
                guard let value = stat.sumQuantity()?.doubleValue(for: unit), value > 0 else {
                    return nil
                }
                return .init(date: stat.startDate, value: value)
            }
            .max { isConsideredBetter($1.value, $0.value) }
    }
    
    private func discreteStat(
        in timeRange: Range<Date>,
        of sampleType: SampleType<HKQuantitySample>,
        option: HealthKit.DiscreteAggregationOption,
        aggregator: (HKStatistics) -> Double?,
        reducer: ([Double]) -> Double?
    ) async -> Double? {
        guard let stats = try? await healthKit.statisticsQuery(
            sampleType,
            aggregatedBy: [option],
            over: .year,
            timeRange: .init(timeRange)
        ) else {
            return nil
        }
        return reducer(stats.compactMap(aggregator))
    }
    
    private func countECGs(in timeRange: Range<Date>) async -> Int? {
        (try? await healthKit.query(.electrocardiogram, timeRange: .init(timeRange)))?.count
    }
    
    private func estimateTotalHeartbeats(in timeRange: Range<Date>) async -> Double {
        // Aggregate by day; for each day's avg BPM, multiply by the actual recorded interval
        // (clamped to the enrollment range). The result undercounts hours the user wasn't
        // wearing the watch, which is fine - we label it as an estimate.
        guard let stats = try? await healthKit.statisticsQuery(
            .heartRate,
            aggregatedBy: [.average],
            over: .day,
            timeRange: .init(timeRange)
        ) else {
            return 0
        }
        return stats.reduce(0) { acc, stat in
            guard let bpm = stat.averageQuantity()?.doubleValue(for: .count() / .minute()) else {
                return acc
            }
            let clamped = stat.timeRange.clamped(to: timeRange)
            let minutes = clamped.timeInterval / 60
            return acc + bpm * minutes
        }
    }
    
    @concurrent
    private func totalSleepSeconds(in timeRange: Range<Date>) async -> Double? {
        guard let samples = try? await healthKit.query(
            .sleepAnalysis,
            timeRange: .init(timeRange)
        ) else {
            return nil
        }
        if let sessions = try? samples.splitIntoSleepSessions() {
            return sessions.reduce(0) { total, session in
                total + session.totalTimeSpentAsleep
            }
        } else {
            // fallback in case we can't compute the sessions.
            // this will be slightly inaccurate, but at least will show _something_
            let asleepValues = HKCategoryValueSleepAnalysis.allAsleepValues.mapIntoSet(\.rawValue)
            return samples.lazy
                .filter { asleepValues.contains($0.value) }
                .reduce(0) { acc, sample in
                    acc + sample.endDate.timeIntervalSince(sample.startDate)
                }
        }
    }
    
    private func loadWorkoutStats(in timeRange: Range<Date>) async -> HealthStats.WorkoutInfo? {
        guard let workouts = try? await healthKit.query(.workout, timeRange: .init(timeRange)) else {
            return nil
        }
        return .init(
            numWorkouts: workouts.count,
            totalDuration: .init(value: workouts.reduce(0.0) { $0 + $1.duration }, unit: .seconds)
        )
    }
    
    private func longestWorkout(in timeRange: Range<Date>) async -> HealthStats.LongestWorkoutInfo? {
        guard let workouts = try? await healthKit.query(.workout, timeRange: .init(timeRange)) else {
            return nil
        }
        return workouts
            .max { $0.duration < $1.duration }
            .map {
                .init(
                    date: $0.startDate,
                    activityType: $0.workoutActivityType,
                    duration: .init(value: $0.duration, unit: .seconds)
                )
            }
    }
}


private func computeWeekStreaks(
    activeWeeks: Set<Date>,
    thisWeek: Date,
    calendar cal: Calendar
) -> (current: Int, longest: Int) {
    guard !activeWeeks.isEmpty else {
        return (0, 0)
    }
    var longest = 0
    var run = 0
    var previous: Date?
    for week in activeWeeks.sorted() {
        if let prev = previous, cal.dateComponents([.weekOfYear], from: prev, to: week).weekOfYear == 1 {
            run += 1
        } else {
            run = 1
        }
        longest = max(longest, run)
        previous = week
    }
    var cursor = thisWeek
    if !activeWeeks.contains(cursor) {
        guard let previousWeek = cal.date(byAdding: .weekOfYear, value: -1, to: cursor) else {
            return (0, longest)
        }
        cursor = previousWeek
    }
    var current = 0
    while activeWeeks.contains(cursor) {
        current += 1
        guard let next = cal.date(byAdding: .weekOfYear, value: -1, to: cursor) else {
            break
        }
        cursor = next
    }
    return (current, longest)
}
