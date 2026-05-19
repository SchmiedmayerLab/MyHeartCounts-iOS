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
import SwiftUI


struct ParticipationStatsView: View {
    @Environment(\.calendar) private var cal
    @Environment(HealthKit.self) private var healthKit
    @Environment(Scheduler.self) private var scheduler

    private let enrollment: StudyEnrollment

    @State private var enrollmentInfo: EnrollmentInfo?
    @State private var engagement: EngagementStats?
    @State private var healthTotals: HealthTotals?
    @State private var personalBests: PersonalBests?

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                heroSection
                engagementSection
                healthTotalsSection
                personalBestsSection
                funFactsSection
            }
            .padding(.horizontal)
            .padding(.bottom, 32)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Participation Stats")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadAll()
        }
        .refreshable {
            await loadAll()
        }
    }

    init(enrollment: StudyEnrollment) {
        self.enrollment = enrollment
    }
}


// MARK: - Sections

extension ParticipationStatsView {
    @ViewBuilder private var heroSection: some View {
        HeroEnrollmentCard(enrollmentDate: enrollment.enrollmentDate, info: enrollmentInfo)
    }

    @ViewBuilder private var engagementSection: some View {
        StatsSection(title: "Engagement", symbol: .checklistChecked) {
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
                format: .dayCount,
                symbol: .flameFill,
                accentColor: .orange
            )
            StatCard(
                title: "Longest Streak",
                value: engagement?.longestStreak,
                format: .dayCount,
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
        StatsSection(title: "Health Totals", symbol: .heartFill) {
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
                value: healthTotals?.totalDistanceMeters,
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
                value: healthTotals?.totalExerciseSeconds,
                format: .duration,
                symbol: .figureRun,
                accentColor: .green
            )
            StatCard(
                title: "Sleep",
                value: healthTotals?.totalSleepSeconds,
                format: .duration,
                symbol: .bedDoubleFill,
                accentColor: .indigo
            )
            StatCard(
                title: "Workouts",
                value: healthTotals?.workoutCount,
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
        StatsSection(title: "Personal Bests", symbol: .starFill) {
            StatCard(
                title: "Best Step Day",
                value: personalBests?.bestDailySteps,
                format: .compactNumber,
                symbol: .figureWalk,
                accentColor: .green,
                subtitle: personalBests?.bestDailyStepsDate.map { formatBestDate($0) }
            )
            StatCard(
                title: "Longest Workout",
                value: personalBests?.longestWorkoutSeconds,
                format: .duration,
                symbol: .stopwatchFill,
                accentColor: .blue,
                subtitle: personalBests?.longestWorkoutDate.map { formatBestDate($0) }
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
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemSymbol: .sparkles)
                        .foregroundStyle(.yellow)
                    Text("Fun Facts")
                        .font(.title3.bold())
                }
                .padding(.horizontal, 4)
                VStack(spacing: 12) {
                    ForEach(funFacts) { fact in
                        FunFactCard(fact: fact)
                    }
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
        if let sleepSec = healthTotals?.totalSleepSeconds, sleepSec > TimeConstants.day {
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


// MARK: - Loading

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
        let range = enrollment.enrollmentDate..<Date.now
        let studyId = enrollment.studyId
        let events: [Event] = (try? scheduler.queryEvents(for: range)) ?? []
        let studyEvents = events.filter { event in
            event.isCompleted && event.task.studyContext?.studyId == studyId
        }
        var perCategory: [Task.Category: Int] = [:]
        var daysWithCompletion = Set<Date>()
        for event in studyEvents {
            if let cat = event.task.category {
                perCategory[cat, default: 0] += 1
            }
            if let completionDate = event.outcome?.completionDate {
                daysWithCompletion.insert(cal.startOfDay(for: completionDate))
            } else {
                daysWithCompletion.insert(cal.startOfDay(for: event.occurrence.start))
            }
        }
        let total = studyEvents.count
        let activeDays = daysWithCompletion.count
        let (current, longest) = computeStreaks(activeDays: daysWithCompletion, today: cal.startOfDay(for: .now))
        let daysSinceEnrollment = (cal.dateComponents(
            [.day],
            from: cal.startOfDay(for: enrollment.enrollmentDate),
            to: cal.startOfDay(for: .now)
        ).day ?? 0) + 1
        let walkRun = (perCategory[.timedWalkingTest] ?? 0) + (perCategory[.timedRunningTest] ?? 0)
        let ecgs = perCategory[.customActiveTask(.ecg)] ?? 0
        let stats = EngagementStats(
            totalCompleted: total,
            questionnairesCompleted: perCategory[.questionnaire] ?? 0,
            articlesRead: perCategory[.informational] ?? 0,
            ecgsRecorded: ecgs,
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

    private func loadHealthTotals() async {
        let startDate = enrollment.enrollmentDate
        let dateRange = startDate..<Date.now
        let timeRange = HealthKitQueryTimeRange.startingAt(startDate)
        async let steps: Int = sumCumulative(.stepCount, unit: .count(), timeRange: timeRange).map { Int($0) } ?? 0
        async let energy: Double = sumCumulative(.activeEnergyBurned, unit: .kilocalorie(), timeRange: timeRange) ?? 0
        async let distance: Double = sumCumulative(.distanceWalkingRunning, unit: .meter(), timeRange: timeRange) ?? 0
        async let exerciseMin: Double = sumCumulative(.appleExerciseTime, unit: .minute(), timeRange: timeRange) ?? 0
        async let flights: Int = sumCumulative(.flightsClimbed, unit: .count(), timeRange: timeRange).map { Int($0) } ?? 0
        async let heartbeats: Double = estimateTotalHeartbeats(in: dateRange)
        async let sleepSec: Double = totalSleepSeconds(in: dateRange)
        async let workoutInfo: (Int, Double) = totalWorkouts(in: dateRange)

        let stats = HealthTotals(
            totalSteps: await steps,
            totalActiveEnergyKcal: await energy,
            totalDistanceMeters: await distance,
            totalExerciseSeconds: await exerciseMin * 60,
            totalFlightsClimbed: await flights,
            totalHeartbeats: Int(await heartbeats),
            totalSleepSeconds: await sleepSec,
            workoutCount: (await workoutInfo).0,
            totalWorkoutSeconds: (await workoutInfo).1
        )
        await MainActor.run {
            self.healthTotals = stats
        }
    }

    private func loadPersonalBests() async {
        let startDate = enrollment.enrollmentDate
        let dateRange = startDate..<Date.now
        let timeRange = HealthKitQueryTimeRange.startingAt(startDate)
        async let bestStepDay: (Int, Date)? = bestDay(
            of: .stepCount,
            unit: .count(),
            timeRange: timeRange
        ).map { (Int($0.value), $0.date) }
        async let longestWorkout: (Double, Date)? = longestWorkout(in: dateRange)
        async let maxHR: Double? = discreteStat(
            .heartRate,
            option: .max,
            aggregator: { $0.maximumQuantity()?.doubleValue(for: .count() / .minute()) },
            timeRange: timeRange,
            reducer: { $0.max() }
        )
        async let avgRestingHR: Double? = discreteStat(
            .restingHeartRate,
            option: .average,
            aggregator: { $0.averageQuantity()?.doubleValue(for: .count() / .minute()) },
            timeRange: timeRange,
            reducer: { $0.isEmpty ? nil : $0.reduce(0, +) / Double($0.count) }
        )

        let stats = PersonalBests(
            bestDailySteps: await bestStepDay?.0,
            bestDailyStepsDate: await bestStepDay?.1,
            longestWorkoutSeconds: await longestWorkout?.0,
            longestWorkoutDate: await longestWorkout?.1,
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
        unit: HKUnit,
        timeRange: HealthKitQueryTimeRange
    ) async -> Double? {
        do {
            let stats = try await healthKit.statisticsQuery(
                sampleType,
                aggregatedBy: [.sum],
                over: .year,
                timeRange: timeRange
            )
            return stats.reduce(0) { $0 + ($1.sumQuantity()?.doubleValue(for: unit) ?? 0) }
        } catch {
            return nil
        }
    }

    private func bestDay(
        of sampleType: SampleType<HKQuantitySample>,
        unit: HKUnit,
        timeRange: HealthKitQueryTimeRange
    ) async -> (value: Double, date: Date)? {
        do {
            let stats = try await healthKit.statisticsQuery(
                sampleType,
                aggregatedBy: [.sum],
                over: .day,
                timeRange: timeRange
            )
            return stats
                .compactMap { stat -> (Double, Date)? in
                    guard let value = stat.sumQuantity()?.doubleValue(for: unit), value > 0 else {
                        return nil
                    }
                    return (value, stat.startDate)
                }
                .max(by: { $0.0 < $1.0 })
        } catch {
            return nil
        }
    }

    private func discreteStat(
        _ sampleType: SampleType<HKQuantitySample>,
        option: HealthKit.DiscreteAggregationOption,
        aggregator: (HKStatistics) -> Double?,
        timeRange: HealthKitQueryTimeRange,
        reducer: ([Double]) -> Double?
    ) async -> Double? {
        do {
            let stats = try await healthKit.statisticsQuery(
                sampleType,
                aggregatedBy: [option],
                over: .year,
                timeRange: timeRange
            )
            return reducer(stats.compactMap(aggregator))
        } catch {
            return nil
        }
    }

    private func estimateTotalHeartbeats(in range: Range<Date>) async -> Double {
        // Aggregate by day; for each day's avg BPM, multiply by the actual recorded interval
        // (clamped to the enrollment range). The result undercounts hours the user wasn't
        // wearing the watch, which is fine - we label it as an estimate.
        do {
            let stats = try await healthKit.statisticsQuery(
                .heartRate,
                aggregatedBy: [.average],
                over: .day,
                timeRange: .init(range)
            )
            return stats.reduce(0) { acc, stat in
                guard let bpm = stat.averageQuantity()?.doubleValue(for: .count() / .minute()) else {
                    return acc
                }
                let clamped = stat.timeRange.clamped(to: range)
                let minutes = clamped.timeInterval / 60
                return acc + bpm * minutes
            }
        } catch {
            return 0
        }
    }

    private func totalSleepSeconds(in range: Range<Date>) async -> Double {
        do {
            let samples = try await healthKit.query(
                .sleepAnalysis,
                timeRange: .init(range)
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
            return 0
        }
    }

    private func totalWorkouts(in range: Range<Date>) async -> (count: Int, totalSeconds: Double) {
        do {
            let workouts = try await healthKit.query(.workout, timeRange: .init(range))
            let total = workouts.reduce(0.0) { $0 + $1.duration }
            return (workouts.count, total)
        } catch {
            return (0, 0)
        }
    }

    private func longestWorkout(in range: Range<Date>) async -> (duration: Double, date: Date)? {
        do {
            let workouts = try await healthKit.query(.workout, timeRange: .init(range))
            return workouts
                .max(by: { $0.duration < $1.duration })
                .map { ($0.duration, $0.startDate) }
        } catch {
            return nil
        }
    }
}


// MARK: - Domain types

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

    fileprivate struct EngagementStats {
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

    fileprivate struct HealthTotals {
        let totalSteps: Int
        let totalActiveEnergyKcal: Double
        let totalDistanceMeters: Double
        let totalExerciseSeconds: Double
        let totalFlightsClimbed: Int
        let totalHeartbeats: Int
        let totalSleepSeconds: Double
        let workoutCount: Int
        let totalWorkoutSeconds: Double
    }

    fileprivate struct PersonalBests {
        let bestDailySteps: Int?
        let bestDailyStepsDate: Date?
        let longestWorkoutSeconds: Double?
        let longestWorkoutDate: Date?
        let maxHeartRateBPM: Int?
        let avgRestingHeartRateBPM: Int?
    }
}


// MARK: - Streak / milestone math

private func computeStreaks(activeDays: Set<Date>, today: Date) -> (current: Int, longest: Int) {
    guard !activeDays.isEmpty else {
        return (0, 0)
    }
    let cal = Calendar.current
    let sorted = activeDays.sorted()
    var longest = 0
    var run = 0
    var previous: Date?
    for day in sorted {
        if let prev = previous, cal.dateComponents([.day], from: prev, to: day).day == 1 {
            run += 1
        } else {
            run = 1
        }
        longest = max(longest, run)
        previous = day
    }
    var cursor = today
    if !activeDays.contains(cursor) {
        guard let yesterday = cal.date(byAdding: .day, value: -1, to: cursor) else {
            return (0, longest)
        }
        cursor = yesterday
    }
    var current = 0
    while activeDays.contains(cursor) {
        current += 1
        guard let next = cal.date(byAdding: .day, value: -1, to: cursor) else {
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

private struct HeroEnrollmentCard: View {
    let enrollmentDate: Date
    let info: ParticipationStatsView.EnrollmentInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let info {
                    Text(info.daysEnrolled, format: .number)
                        .font(.system(size: 64, weight: .bold, design: .rounded))
                        .contentTransition(.numericText(value: Double(info.daysEnrolled)))
                        .monospacedDigit()
                } else {
                    Text("—")
                        .font(.system(size: 64, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Text("days")
                    .font(.title2.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Enrolled since")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Text(enrollmentDate, format: .dateTime.year().month(.wide).day())
                    .font(.headline)
            }
            if let info {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Next milestone")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        Spacer()
                        Text("\(info.nextMilestone, format: .number) days")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    ProgressView(value: info.progressToNext)
                        .progressViewStyle(.linear)
                        .tint(.pink)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}


private struct StatsSection<Content: View>: View {
    let title: LocalizedStringResource
    let symbol: SFSymbol
    @ViewBuilder let content: Content

    private let columns: [GridItem] = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemSymbol: symbol)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.title3.bold())
            }
            .padding(.horizontal, 4)
            LazyVGrid(columns: columns, spacing: 12) {
                content
            }
        }
    }
}


private struct StatCard: View {
    enum Format {
        case number
        case compactNumber
        case dayCount
        case distance       // expects meters
        case energyKcal     // expects kcal
        case duration       // expects seconds
        case heartRate      // expects BPM
    }

    let title: LocalizedStringResource
    let value: Double?
    let format: Format
    let symbol: SFSymbol
    let accentColor: Color
    let subtitle: String?

    init<V: BinaryInteger>(
        title: LocalizedStringResource,
        value: V?,
        format: Format,
        symbol: SFSymbol,
        accentColor: Color,
        subtitle: String? = nil
    ) {
        self.title = title
        self.value = value.map { Double($0) }
        self.format = format
        self.symbol = symbol
        self.accentColor = accentColor
        self.subtitle = subtitle
    }

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
        .background(.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
        .background(.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
