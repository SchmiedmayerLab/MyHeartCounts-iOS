//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

// swiftlint:disable all

import Foundation
import HealthKit
import MHCStudyDefinition
import SFSafeSymbols
import SpeziFoundation
import SpeziHealthKit
import SpeziScheduler
import SpeziStudy
import SpeziViews
import SwiftUI
import OSLog

private let statsLogger = Logger(subsystem: "edu.stanford.MHC", category: "Stats")


/// Displays interesting (though not necessarily scientificaly useful) statisics about the user's participation in the study.
struct ParticipationStatsView: View {
    @Environment(\.calendar) private var cal
    @Environment(HealthKit.self) private var healthKit
    @Environment(Scheduler.self) private var scheduler
    @Environment(AchievementsManager.self) private var achievementsManager
    
    private let enrollment: StudyEnrollment
//    @Environment(ParticipationStatsProvider.self) private var stats
    @State private var enrollmentTimeRange: Range<Date>
//
//    
    private var enrollmentHealthQueryTimeRange: HealthKitQueryTimeRange {
        .init(cal.startOfDay(for: enrollmentTimeRange.lowerBound)..<enrollmentTimeRange.upperBound)
    }
    
    @State private var isShowingExplainerSheet = false
    
    @State private var enrollmentInfo: EnrollmentInfo?
    @State private var engagement: EngagementStats?
    @State private var healthTotals: HealthTotals?
    @State private var personalBests: PersonalBests?
    
    var body: some View {
        Form {
            EnrollmentStatsSection(enrollmentDate: enrollment.enrollmentDate)
            engagementSection
            healthTotalsSection
            personalBestsSection
            funFactsSection
        }
        .navigationTitle("Stats and Achievements")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: enrollmentTimeRange) {
            await loadAll()
        }
        .refreshable {
            // updating the time range here will trigger the task above, which will update the stats
            enrollmentTimeRange = ParticipationStatsProvider.enrollmentTimeRange(for: enrollment, upTo: .now)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isShowingExplainerSheet = true
                } label: {
                    Label("Info" as String, systemSymbol: .infoCircle)
                        .labelStyle(.iconOnly)
                }
            }
        }
        .sheet(isPresented: $isShowingExplainerSheet) {
            NavigationStack {
                ScrollView {
                    Text(verbatim: """
                        Participation Stats cover all engagement and activity recorded.
                        Your enrollment date is \(enrollment.enrollmentDate.formatted(.dateTime)).
                        """)
                    // Note that leaving the study (e.g., by deleting the app or logging out) and re-enrolling will reset some of the engagement-related statistics.
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.red)
                    .padding(.horizontal)
                }
                .navigationTitle("Info" as String) // ???
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        DismissButton()
                    }
                }
            }
        }
    }

    init(enrollment: StudyEnrollment) {
        self.enrollment = enrollment
        self.enrollmentTimeRange = ParticipationStatsProvider.enrollmentTimeRange(for: enrollment, upTo: .now)
    }
}


// MARK: - Sections

extension ParticipationStatsView {
    @ViewBuilder private var engagementSection: some View {
        TiledSection("Engagement", symbol: .checklistChecked) {
            StatCard(
                title: "Tasks Done",
                value: engagement?.totalCompleted,
                format: .number,
                symbol: .checkmarkCircleFill,
                accentColor: .accentColor
            )
            StatCard(
                title: "Current Streak",
                value: engagement?.currentStreak,
                format: .weekCount,
                symbol: .flameFill,
                accentColor: .orange
            )
            StatCard(
                title: "Longest Streak",
                value: engagement?.longestStreak,
                format: .weekCount,
                symbol: .trophyFill,
                accentColor: .yellow
            )
            StatCard(
                title: "Active Days",
                value: engagement?.activeDays,
                format: .number,
                symbol: .calendarBadgeCheckmark,
                accentColor: .green,
                subtitle: engagement.map { activeDaysSubtitle(active: $0.activeDays, totalDays: $0.daysSinceEnrollment) }
            )
            StatCard(
                title: "Surveys Answered",
                value: engagement?.questionnairesCompleted,
                format: .number,
                symbol: .listClipboardFill,
                accentColor: .purple
            )
            StatCard(
                title: "Articles Read",
                value: engagement?.articlesRead,
                format: .number,
                symbol: .bookFill,
                accentColor: .brown
            )
            StatCard(
                title: "ECGs Recorded",
                value: engagement?.ecgsRecorded,
                format: .number,
                symbol: .waveformPathEcgRectangle,
                accentColor: .red
            )
            StatCard(
                title: "Walk / Run Tests",
                value: engagement?.walkRunTestsCompleted,
                format: .number,
                symbol: .figureWalk,
                accentColor: .blue
            )
        }
    }

    @ViewBuilder private var healthTotalsSection: some View {
        TiledSection("Health Totals", symbol: .heartFill) {
            StatCard(
                title: "Steps",
                value: healthTotals?.totalSteps,
                format: .compactNumber,
                symbol: .figureWalk,
                accentColor: .green
            )
            StatCard(
                title: "Heartbeats",
                value: healthTotals?.totalHeartbeats,
                format: .compactNumber,
                symbol: .heartFill,
                accentColor: .red,
                subtitle: "Estimate"
            )
            StatCard(
                title: "Distance",
                value: healthTotals?.totalDistanceWalkingRunning?.value,
                format: .distance,
                symbol: .mapFill,
                accentColor: .blue
            )
            StatCard(
                title: "Active Energy",
                value: healthTotals?.totalActiveEnergyKcal,
                format: .energyKcal,
                symbol: .flameFill,
                accentColor: .orange
            )
            StatCard(
                title: "Exercise Time",
                value: healthTotals?.totalExerciseTime?.value,
                format: .duration,
                symbol: .figureRun,
                accentColor: .green
            )
            StatCard(
                title: "Sleep",
                value: healthTotals?.totalSleepTime?.value,
                format: .duration,
                symbol: .bedDoubleFill,
                accentColor: .indigo
            )
            StatCard(
                title: "Workouts",
                value: healthTotals?.workoutInfo?.numWorkouts,
                format: .number,
                symbol: .figureCooldown,
                accentColor: .teal
            )
            StatCard(
                title: "Flights Climbed",
                value: healthTotals?.totalFlightsClimbed,
                format: .number,
                symbol: .figureStairs,
                accentColor: .cyan
            )
        }
    }

    @ViewBuilder private var personalBestsSection: some View {
        TiledSection("Personal Bests", symbol: .starFill) {
            StatCard(
                title: "Best Step Day",
                value: personalBests?.bestDailySteps?.value,
                format: .compactNumber,
                symbol: .figureWalk,
                accentColor: .green,
                subtitle: (personalBests?.bestDailySteps?.date).map { formatBestDate($0) }
            )
            StatCard(
                title: "Longest Workout",
                value: personalBests?.longestWorkoutDuration?.value.value,
                format: .duration,
                symbol: .stopwatchFill,
                accentColor: .blue,
                subtitle: (personalBests?.longestWorkoutDuration?.date).map { formatBestDate($0) }
            )
            StatCard(
                title: "Max Heart Rate",
                value: personalBests?.maxHeartRateBPM,
                format: .heartRate,
                symbol: .heartFill,
                accentColor: .red
            )
            StatCard(
                title: "Resting HR",
                value: personalBests?.avgRestingHeartRateBPM,
                format: .heartRate,
                symbol: .bedDoubleFill,
                accentColor: .pink,
                subtitle: "Average"
            )
        }
    }

    @ViewBuilder private var funFactsSection: some View {
        if let funFacts = makeFunFacts(), !funFacts.isEmpty {
            Section {
                ForEach(funFacts) { fact in
                    FunFactCard(fact: fact)
                        .listRowInsets(.zero)
                        .listRowBackground(Color.clear)
                }
            } header: {
                Label {
                    Text("Fun Facts")
                } icon: {
                    Image(systemSymbol: .sparkles)
                }
            }
        }
    }
}


// MARK: - Helpers

extension ParticipationStatsView {
    private func activeDaysSubtitle(active: Int, totalDays: Int) -> String {
        let percent = totalDays > 0 ? Double(active) / Double(totalDays) : 0
        return "\(percent.formatted(.percent.precision(.fractionLength(0)))) of days"
    }

    private func formatBestDate(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day())
    }

    private func makeFunFacts() -> [FunFact]? {
        var facts: [FunFact] = []
        if let steps = healthTotals?.totalSteps, steps > 0 {
            let distanceKm = Double(steps) * 0.000762 // ~0.762m per step
            let isMetric = Locale.current.measurementSystem != .us
            let distanceFormatted: String = {
                let measurement = Measurement<UnitLength>(value: distanceKm, unit: .kilometers)
                let converted = isMetric ? measurement : measurement.converted(to: .miles)
                return converted.formatted(.measurement(width: .abbreviated, numberFormatStyle: .number.precision(.fractionLength(0))))
            }()
            if let comparison = stepDistanceComparison(distanceKm: distanceKm) {
                facts.append(.init(
                    symbol: .figureWalk,
                    color: .green,
                    text: "Your \(steps.formatted(.number)) steps cover about \(distanceFormatted) \u{2014} that's \(comparison)."
                ))
            } else {
                facts.append(.init(
                    symbol: .figureWalk,
                    color: .green,
                    text: "Your \(steps.formatted(.number)) steps cover roughly \(distanceFormatted)."
                ))
            }
        }
        if let beats = healthTotals?.totalHeartbeats, beats > 0 {
            let lifetimePercent = Double(beats) / 3_000_000_000
            let percentFormatted = lifetimePercent.formatted(.percent.precision(.fractionLength(0...2)))
            facts.append(.init(
                symbol: .heartFill,
                color: .red,
                text: "Your heart has beaten about \(beats.formatted(.number.notation(.compactName))) times since you enrolled \u{2014} roughly \(percentFormatted) of an average lifetime."
            ))
        }
        if let kcal = healthTotals?.totalActiveEnergyKcal, kcal > 0 {
            let pizzaSlices = Int((kcal / 285).rounded())
            if pizzaSlices > 0 {
                facts.append(.init(
                    symbol: .flameFill,
                    color: .orange,
                    text: "You've burned \(Int(kcal).formatted(.number)) active calories \u{2014} the equivalent of \(pizzaSlices.formatted(.number)) slices of pizza."
                ))
            }
        }
        if let sleepSec = healthTotals?.totalSleepTime?.value(in: .seconds), sleepSec > TimeConstants.day {
            let days = sleepSec / TimeConstants.day
            facts.append(.init(
                symbol: .bedDoubleFill,
                color: .indigo,
                text: "You've spent about \(days.formatted(.number.precision(.fractionLength(1)))) full days asleep since enrolling. Rest is part of the work."
            ))
        }
        if let active = engagement?.activeDays, let total = engagement?.daysSinceEnrollment, total > 0 {
            let percent = Double(active) / Double(total)
            if percent >= 0.7 {
                facts.append(.init(
                    symbol: .starFill,
                    color: .yellow,
                    text: "You've been active on \(active.formatted(.number)) of \(total.formatted(.number)) days \u{2014} that's a fantastic \(percent.formatted(.percent.precision(.fractionLength(0)))). Keep it up!"
                ))
            }
        }
        return facts
    }

    private func stepDistanceComparison(distanceKm: Double) -> String? {
        // Pick the most "fun" reference for the user's actual distance.
        if distanceKm >= 20_000 {
            let earths = distanceKm / 40_075
            return "about \(earths.formatted(.number.precision(.fractionLength(1)))) trips around the Earth"
        } else if distanceKm >= 1_000 {
            let coastToCoast = distanceKm / 3_940 // SF to NY
            return "roughly \(coastToCoast.formatted(.number.precision(.fractionLength(1)))) trips from San Francisco to New York"
        } else if distanceKm >= 50 {
            let marathons = distanceKm / 42.195
            return "the distance of \(marathons.formatted(.number.precision(.fractionLength(1)))) marathons"
        } else if distanceKm >= 5 {
            let bridges = distanceKm / 2.737 // Golden Gate Bridge length
            return "\(Int(bridges.rounded())) lengths of the Golden Gate Bridge"
        } else if distanceKm >= 0.5 {
            let laps = (distanceKm * 1000) / 400 // 400m track
            return "\(Int(laps.rounded())) laps around a running track"
        } else {
            return nil
        }
    }
}


// MARK: Stats

extension ParticipationStatsView {
    fileprivate struct EnrollmentInfo {
        let daysEnrolled: Int
        let previousMilestone: Int
        let nextMilestone: Int
        
        var progressToNext: Double {
            guard nextMilestone > previousMilestone else {
                return 1
            }
            let span = Double(nextMilestone - previousMilestone)
            let progress = Double(daysEnrolled - previousMilestone)
            return max(0, min(1, progress / span))
        }
    }
    
    
    private struct EngagementStats {
        let totalCompleted: Int
        let questionnairesCompleted: Int
        let articlesRead: Int
        let ecgsRecorded: Int
        let walkRunTestsCompleted: Int
        let activeDays: Int
        let daysSinceEnrollment: Int
        let currentStreak: Int
        let longestStreak: Int
    }
    
    
    private struct HealthTotals {
        struct WorkoutInfo {
            let numWorkouts: Int
            let totalDuration: Measurement<UnitDuration>
        }
        let totalSteps: Int?
        let totalActiveEnergyKcal: Double?
        let totalDistanceWalkingRunning: Measurement<UnitLength>?
        let totalExerciseTime: Measurement<UnitDuration>?
        let totalFlightsClimbed: Int?
        let totalHeartbeats: Int?
        let totalSleepTime: Measurement<UnitDuration>?
        let workoutInfo: WorkoutInfo?
    }
    
    
    private struct PersonalBests: Sendable {
        struct Entry<Value: Sendable>: Sendable {
            let date: Date
            let value: Value
            
            func map<NewValue>(_ transform: (Value) -> NewValue) -> Entry<NewValue> {
                .init(date: date, value: transform(value))
            }
        }
        
        let bestDailySteps: Entry<Int>?
        let longestWorkoutDuration: Entry<Measurement<UnitDuration>>?
        let maxHeartRateBPM: Int?
        let avgRestingHeartRateBPM: Int?
    }
}


extension ParticipationStatsView {
    private func loadAll() async {
        async let enrollment: Void = loadEnrollmentInfo()
        async let engagement: Void = loadEngagement()
        async let totals: Void = loadHealthTotals()
        async let bests: Void = loadPersonalBests()
        _ = await (enrollment, engagement, totals, bests)
    }

    private func loadEnrollmentInfo() async {
        let enrollmentDay = cal.startOfDay(for: enrollment.enrollmentDate)
        let today = cal.startOfDay(for: .now)
        let days = cal.dateComponents([.day], from: enrollmentDay, to: today).day ?? 0
        let (prev, next) = milestones(around: days)
        await MainActor.run {
            self.enrollmentInfo = .init(daysEnrolled: days, previousMilestone: prev, nextMilestone: next)
        }
    }

    private func loadEngagement() async {
        // ECGs come from HealthKit rather than from Scheduler outcomes so the count survives a
        // reinstall (HealthKit data persists; the Scheduler's local task-completion store does not).
        async let ecgCount = countECGs(in: enrollmentTimeRange)
        let events: [Event] = (try? scheduler.queryEvents(for: cal.startOfDay(for: enrollmentTimeRange.lowerBound)..<Date.now)) ?? []
        let studyEvents = events.filter { event in
            event.isCompleted && event.task.studyContext?.studyId == enrollment.studyId
        }
        var perCategory: [Task.Category: Int] = [:]
        var daysWithCompletion = Set<Date>()
        var weeksWithCompletion = Set<Date>()
        for event in studyEvents {
            if let cat = event.task.category {
                perCategory[cat, default: 0] += 1
            }
            let date = event.outcome?.completionDate ?? event.occurrence.start
            daysWithCompletion.insert(cal.startOfDay(for: date))
            if let weekStart = cal.dateInterval(of: .weekOfYear, for: date)?.start {
                weeksWithCompletion.insert(weekStart)
            }
        }
        let activeDays = daysWithCompletion.count
        let thisWeekStart = cal.dateInterval(of: .weekOfYear, for: .now)?.start ?? cal.startOfDay(for: .now)
        let (current, longest) = computeWeekStreaks(activeWeeks: weeksWithCompletion, thisWeek: thisWeekStart, calendar: cal)
        let daysSinceEnrollment = (cal.dateComponents(
            [.day],
            from: cal.startOfDay(for: enrollment.enrollmentDate),
            to: cal.startOfDay(for: .now)
        ).day ?? 0) + 1
        let walkRun = (perCategory[.timedWalkingTest] ?? 0) + (perCategory[.timedRunningTest] ?? 0)
        let stats = EngagementStats(
            totalCompleted: studyEvents.count,
            questionnairesCompleted: perCategory[.questionnaire] ?? 0,
            articlesRead: perCategory[.informational] ?? 0,
            ecgsRecorded: (await ecgCount) ?? 0,
            walkRunTestsCompleted: walkRun,
            activeDays: activeDays,
            daysSinceEnrollment: daysSinceEnrollment,
            currentStreak: current,
            longestStreak: longest
        )
        await MainActor.run {
            self.engagement = stats
        }
    }

    /// Counts the number of ECGs recorded during the enrollment time range, sourced from HealthKit.
    private func countECGs(in range: Range<Date>) async -> Int? {
        do {
            return try await healthKit.query(.electrocardiogram, timeRange: .init(range)).count
        } catch {
            return nil
        }
    }

    private func loadHealthTotals() async {
        async let steps = sumCumulative(.stepCount, unit: .count()).map { Int($0) }
        async let energy = sumCumulative(.activeEnergyBurned, unit: .kilocalorie())
        async let distance = sumCumulative(.distanceWalkingRunning, unit: .meter())
        async let exerciseMin = sumCumulative(.appleExerciseTime, unit: .minute())
        async let flights = sumCumulative(.flightsClimbed, unit: .count()).map { Int($0) }
        async let heartbeats = estimateTotalHeartbeats()
        async let sleepSec = totalSleepSeconds()
        async let workoutStats = loadWorkoutStats(in: enrollmentTimeRange)
        let stats = HealthTotals(
            totalSteps: await steps,
            totalActiveEnergyKcal: await energy,
            totalDistanceWalkingRunning: (await distance).map { .init(value: $0, unit: .meters) },
            totalExerciseTime: await exerciseMin.map { .init(value: $0 * 60, unit: .seconds) },
            totalFlightsClimbed: await flights,
            totalHeartbeats: Int(await heartbeats),
            totalSleepTime: (await sleepSec).map { .init(value: $0, unit: .seconds) },
            workoutInfo: await workoutStats
        )
        statsLogger.notice("#workouts: \(stats.workoutInfo?.numWorkouts ?? 0)")
        await MainActor.run {
            self.healthTotals = stats
        }
    }
    
    private func loadPersonalBests() async {
        async let bestStepDay = bestDay(of: .stepCount, unit: .count())?.map { Int($0) }
        async let longestWorkout = longestWorkout(in: enrollmentTimeRange)
        async let maxHR: Double? = discreteStat(
            .heartRate,
            option: .max,
            aggregator: { $0.maximumQuantity()?.doubleValue(for: .count() / .minute()) },
            reducer: { $0.max() }
        )
        async let avgRestingHR: Double? = discreteStat(
            .restingHeartRate,
            option: .average,
            aggregator: { $0.averageQuantity()?.doubleValue(for: .count() / .minute()) },
            reducer: { $0.isEmpty ? nil : $0.reduce(0, +) / Double($0.count) }
        )
        let stats = PersonalBests(
            bestDailySteps: await bestStepDay,
            longestWorkoutDuration: await longestWorkout,
            maxHeartRateBPM: (await maxHR).map { Int($0.rounded()) },
            avgRestingHeartRateBPM: (await avgRestingHR).map { Int($0.rounded()) }
        )
        await MainActor.run {
            self.personalBests = stats
        }
    }
}


// MARK: - HealthKit query helpers



extension ParticipationStatsView {
    private func sumCumulative(
        _ sampleType: SampleType<HKQuantitySample>,
        unit: HKUnit
    ) async -> Double? {
        do {
            let stats = try await healthKit.statisticsQuery(
                sampleType,
                aggregatedBy: [.sum],
                over: .year,
                timeRange: enrollmentHealthQueryTimeRange
            )
            return stats.reduce(0) { $0 + ($1.sumQuantity()?.doubleValue(for: unit) ?? 0) }
        } catch {
            return nil
        }
    }

    private func bestDay(
        of sampleType: SampleType<HKQuantitySample>,
        unit: HKUnit
    ) async -> PersonalBests.Entry<Double>? {
        do {
            let stats = try await healthKit.statisticsQuery(
                sampleType,
                aggregatedBy: [.sum],
                over: .day,
                timeRange: enrollmentHealthQueryTimeRange
            )
            return stats
                .compactMap { stat -> PersonalBests.Entry<Double>? in
                    guard let value = stat.sumQuantity()?.doubleValue(for: unit), value > 0 else { // TODO why the value > 0 check?
                        return nil
                    }
                    return .init(date: stat.startDate, value: value)
                }
                .max { $0.value < $1.value }
        } catch {
            return nil
        }
    }

    private func discreteStat(
        _ sampleType: SampleType<HKQuantitySample>,
        option: HealthKit.DiscreteAggregationOption,
        aggregator: (HKStatistics) -> Double?,
        reducer: ([Double]) -> Double?
    ) async -> Double? {
        do {
            let stats = try await healthKit.statisticsQuery(
                sampleType,
                aggregatedBy: [option],
                over: .year,
                timeRange: enrollmentHealthQueryTimeRange
            )
            return reducer(stats.compactMap(aggregator))
        } catch {
            return nil
        }
    }

    private func estimateTotalHeartbeats() async -> Double {
        // Aggregate by day; for each day's avg BPM, multiply by the actual recorded interval
        // (clamped to the enrollment range). The result undercounts hours the user wasn't
        // wearing the watch, which is fine - we label it as an estimate.
        let range = enrollmentHealthQueryTimeRange
        do {
            let stats = try await healthKit.statisticsQuery(
                .heartRate,
                aggregatedBy: [.average],
                over: .day,
                timeRange: range
            )
            return stats.reduce(0) { acc, stat in
                guard let bpm = stat.averageQuantity()?.doubleValue(for: .count() / .minute()) else {
                    return acc
                }
                let clamped = stat.timeRange.clamped(to: range.range)
                let minutes = clamped.timeInterval / 60
                return acc + bpm * minutes
            }
        } catch {
            return 0
        }
    }

    private func totalSleepSeconds() async -> Double? {
        do {
            let samples = try await healthKit.query(
                .sleepAnalysis,
                timeRange: enrollmentHealthQueryTimeRange
            )
            let asleepValues: Set<Int> = [
                HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
                HKCategoryValueSleepAnalysis.asleepCore.rawValue,
                HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
                HKCategoryValueSleepAnalysis.asleepREM.rawValue
            ]
            return samples
                .filter { asleepValues.contains($0.value) }
                .reduce(0) { acc, sample in
                    acc + sample.endDate.timeIntervalSince(sample.startDate)
                }
        } catch {
            return nil
        }
    }

    private func loadWorkoutStats(in range: Range<Date>) async -> HealthTotals.WorkoutInfo? {
        do {
            let workouts = try await healthKit.query(.workout, timeRange: .init(range))
            return .init(
                numWorkouts: workouts.count,
                totalDuration: .init(value: workouts.reduce(0.0) { $0 + $1.duration }, unit: .seconds)
            )
        } catch {
            return nil
        }
    }

    private func longestWorkout(in range: Range<Date>) async -> PersonalBests.Entry<Measurement<UnitDuration>>? {
        do {
            let workouts = try await healthKit.query(.workout, timeRange: .init(range))
            return workouts
                .max { $0.duration < $1.duration }
                .map { .init(date: $0.startDate, value: .init(value: $0.duration, unit: .seconds)) }
        } catch {
            return nil
        }
    }
}


// MARK: - Streak / milestone math

/// Computes streak metrics over a set of week-start dates.
///
/// A "week" here is one entry in `activeWeeks`, normalized to the start of the week (as produced by
/// `Calendar.dateInterval(of: .weekOfYear, for:)`). Two weeks are considered adjacent if they're
/// exactly one `.weekOfYear` apart, so the math respects the user's locale/firstWeekday.
///
/// The current streak walks back from `thisWeek`. If the current week has no completions yet,
/// we tolerate that and start the streak at the previous week — losing your streak the moment a new
/// week begins (and before you've had a chance to complete anything in it) would be punishing,
/// especially given that study tasks have at most a biweekly cadence.
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


private func milestones(around days: Int) -> (previous: Int, next: Int) {
    let fixed = [1, 7, 30, 60, 100, 200, 365]
    var all = fixed
    var year = 2
    while all.last ?? 0 <= days + 365 {
        all.append(365 * year)
        year += 1
    }
    let prev = all.last(where: { $0 <= days }) ?? 0
    let next = all.first(where: { $0 > days }) ?? (prev + 365)
    return (prev, next)
}




// MARK: - Subviews


private struct EnrollmentStatsSection: View {
    @Environment(AchievementsManager.self) private var achievements
    
    let enrollmentDate: Date

    var body: some View {
        Section {
            NavigationLink {
                AchievementsView()
            } label: {
                // bc we want the whole section to act as a single button that opens the achievements
                // (which we achieve by placing all content in a giant NavigationLink), we need to
                // build up the Form-like layout by hand.
                Group(subviews: sectionContent) { subviews in
                    VStack(alignment: .leading, spacing: 15) {
                        ForEach(subviews) { subview in
                            if subview.id != subviews.first?.id {
                                Divider()
                            }
                            subview
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .navigationLinkIndicatorVisibility(.hidden)
        }
    }
    
    private var nextEnrollmentDurationAchievement: Achievement? {
        achievements.nextLockedAchievement(in: .studyParticipation, subcategory: .enrollmentDuration)
    }
    
    
    @ViewBuilder private var sectionContent: some View {
        daysEnrolledRow
        achievementsRow
    }
    
    @ViewBuilder
    private var daysEnrolledRow: some View {
        let numDaysEnrolled = Calendar.current.countDistinctDays(from: enrollmentDate, to: .now)
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(numDaysEnrolled, format: .number)
                    .font(.system(size: 64, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("days")
                    .font(.title2.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Enrolled since")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    Text(enrollmentDate, format: .dateTime.year().month(.wide).day())
                        .font(.headline)
                }
                Spacer()
                if let achievement = nextEnrollmentDurationAchievement {
                    achievementInfoCapsule(for: achievement)
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            HStack {
                Image(systemSymbol: .medalStar)
                    .accessibilityLabel("Achievements")
                    .imageScale(.small)
                VStack {
                    let numUnlocked = achievements.userDisplayableUnlockedAchievementsCount
                    let numTotal = achievements.userDisplayableTotalAchievementCount
                    Text("\(numUnlocked, format: .number) / \(numTotal, format: .number)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    ProgressView(value: Double(numUnlocked) / Double(numTotal))
                        .frame(maxWidth: 41)
                }
            }
        }
    }
    
    @ViewBuilder
    private var achievementsRow: some View {
        let upcoming = achievements
            .nextLockedAchievements(excluding: nextEnrollmentDurationAchievement.map { [$0] } ?? [])
            .prefix(3)
        if !upcoming.isEmpty {
            VStack(alignment: .leading) {
                Text("Upcoming Achievements")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                ForEach(upcoming, id: \.achievement) { upcoming in
                    let achievement = upcoming.achievement
                    achievementInfoCapsule(for: achievement)
                }
            }
        }
    }
    
    @ViewBuilder
    private var nextAchievementRow: some View {
        if let achievement = achievements.nextLockedAchievement(in: .studyParticipation, subcategory: .enrollmentDuration) {
            let state = achievements.state(of: achievement)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Next milestone")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    Spacer()
                    Text(achievement.title)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: state.progress)
                    .progressViewStyle(.linear)
            }
        }
    }
    
    private func achievementInfoCapsule(for achievement: Achievement) -> some View {
        HStack {
            AchievementIcon(achievement: achievement)
            VStack(alignment: .leading) {
                Text(achievement.title)
                    .font(.caption)
                Text(achievement.description)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}


private struct StatCard: View {
    enum Format {
        case number
        case compactNumber
        case dayCount
        case weekCount
        /// in meters
        case distance
        /// in kcal
        case energyKcal
        /// in seconds
        case duration
        /// in BPM
        case heartRate
    }

    let title: LocalizedStringResource
    let subtitle: String?
    let value: Double?
    let format: Format
    let symbol: SFSymbol
    let accentColor: Color

    init<V: BinaryInteger>(
        title: LocalizedStringResource,
        value: V?,
        format: Format,
        symbol: SFSymbol,
        accentColor: Color,
        subtitle: String? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.value = value.map { Double($0) }
        self.format = format
        self.symbol = symbol
        self.accentColor = accentColor
    }
    
//    init<D>(
//        title: LocalizedStringResource,
//        value: Measurement<D>,
//        format: Format,
//        symbol: SFSymbol,
//        accentColor: Color,
//        subtitle: String? = nil
//    ) {
//        
//    }

    init(
        title: LocalizedStringResource,
        value: Double?,
        format: Format,
        symbol: SFSymbol,
        accentColor: Color,
        subtitle: String? = nil
    ) {
        self.title = title
        self.value = value
        self.format = format
        self.symbol = symbol
        self.accentColor = accentColor
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemSymbol: symbol)
                    .font(.callout)
                    .foregroundStyle(accentColor)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer()
            }
            Group {
                if let value {
                    formattedValue(value)
                } else {
                    Text("—")
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.system(size: 22, weight: .bold, design: .rounded))
            .monospacedDigit()
            .contentTransition(.numericText(value: value ?? 0))
            .minimumScaleFactor(0.6)
            .lineLimit(1)
            if let subtitle {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            } else {
                Text(" ").font(.caption2) // keep card height consistent
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardTileBackground(cornerRadius: 14)
    }

    @ViewBuilder
    private func formattedValue(_ value: Double) -> some View {
        switch format {
        case .number:
            Text(Int(value), format: .number)
        case .compactNumber:
            Text(Int(value), format: .number.notation(.compactName))
        case .dayCount:
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(Int(value), format: .number)
                Text("d").font(.title3.weight(.medium)).foregroundStyle(.secondary)
            }
        case .weekCount:
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(Int(value), format: .number)
                Text("w").font(.title3.weight(.medium)).foregroundStyle(.secondary)
            }
        case .distance:
            let measurement = Measurement<UnitLength>(value: value, unit: .meters)
            Text(measurement.formatted(.measurement(
                width: .abbreviated,
                usage: .road,
                numberFormatStyle: .number.precision(.fractionLength(0))
            )))
        case .energyKcal:
            let measurement = Measurement<UnitEnergy>(value: value, unit: .kilocalories)
            Text(measurement.formatted(.measurement(width: .abbreviated, numberFormatStyle: .number.notation(.compactName))))
        case .duration:
            Text(formatDuration(seconds: value))
        case .heartRate:
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(Int(value), format: .number)
                Text("bpm").font(.title3.weight(.medium)).foregroundStyle(.secondary)
            }
        }
    }

    private func formatDuration(seconds: Double) -> String {
        let totalMinutes = Int(seconds / 60)
        if totalMinutes >= 60 * 24 {
            let days = totalMinutes / (60 * 24)
            let hours = (totalMinutes / 60) % 24
            return hours == 0 ? "\(days)d" : "\(days)d \(hours)h"
        } else if totalMinutes >= 60 {
            let hours = totalMinutes / 60
            let minutes = totalMinutes % 60
            return minutes == 0 ? "\(hours)h" : "\(hours)h \(minutes)m"
        } else {
            return "\(totalMinutes)m"
        }
    }
}


private struct FunFact: Identifiable {
    let id = UUID()
    let symbol: SFSymbol
    let color: Color
    let text: String
}


private struct FunFactCard: View {
    let fact: FunFact

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemSymbol: fact.symbol)
                .font(.title3)
                .foregroundStyle(fact.color)
                .frame(width: 28, height: 28)
//                .background(fact.color.opacity(0.12), in: Circle())
            Text(fact.text)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardTileBackground(cornerRadius: 0 /*14*/)
    }
}



extension Measurement {
    func value(in unit: UnitType) -> Double where UnitType: Dimension {
        self.converted(to: unit).value
    }
}


// MARK: TMP

struct ParticipationStatsButton: View {
    @Environment(StudyManager.self)
    private var studyManager: StudyManager?
    
    @State private var showStats = false
    
    var body: some View {
        Button {
            showStats = true
        } label: {
            Label(symbol: .medalStar) {
                Text("Stats and Achievements")
            }
        }
        .sheet(isPresented: $showStats) {
            if let enrollment = studyManager?.studyEnrollments.first {
                NavigationStack {
                    ParticipationStatsView(enrollment: enrollment)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                DismissButton()
                            }
                        }
                }
            }
        }
    }
}
