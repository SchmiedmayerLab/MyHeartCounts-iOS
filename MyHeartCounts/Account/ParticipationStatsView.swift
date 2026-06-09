//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

// swiftlint:disable attributes file_types_order file_length

import Foundation
import SFSafeSymbols
import SpeziFoundation
import SpeziStudy
import SpeziViews
import SwiftUI


/// Displays interesting (though not necessarily scientificaly useful) statisics about the user's participation in the study.
struct ParticipationStatsView: View {
    @Environment(\.calendar) private var cal
    @Environment(ParticipationStatsProvider.self) private var statsProvider
    @Environment(AchievementsManager.self) private var achievementsManager
    
    private let enrollment: StudyEnrollment
    @State private var stats: ParticipationStatsProvider.Stats?
    @State private var isShowingExplainerSheet = false
    
    var body: some View {
        Form {
            EnrollmentStatsSection(enrollmentDate: enrollment.enrollmentDate)
            TiledSection("Engagement"/*, symbol: .checklistChecked*/) {
                engagementSection(using: stats)
            }
            TiledSection("Health Totals"/*, symbol: .heartFill*/) {
                healthTotalsSection(using: stats?.health)
            }
            TiledSection("Personal Bests"/*, symbol: .starFill*/) {
                personalBestsSection(using: stats?.health.personalBests)
            }
            funFactsSection()
        }
        .navigationTitle("Stats and Achievements")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await updateStats()
        }
        .refreshable {
            await updateStats()
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isShowingExplainerSheet = true
                } label: {
                    Label("Info", systemSymbol: .infoCircle)
                        .labelStyle(.iconOnly)
                }
            }
        }
        .sheet(isPresented: $isShowingExplainerSheet) {
            NavigationStack {
                ScrollView {
                    Text("PARTICIPATION_STATS_EXPLAINER(enrollmentDate: \(enrollment.enrollmentDate, format: .dateTime))")
                    // Note that leaving the study (e.g., by deleting the app or logging out) and re-enrolling will reset some of the engagement-related statistics.
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                }
                .navigationTitle("Info")
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
    }
    
    private func updateStats() async {
        stats = await statsProvider.computeStats(for: enrollment)
    }
}


// MARK: - Sections

extension ParticipationStatsView {
    @ViewBuilder
    private func engagementSection( // swiftlint:disable:this function_body_length
        using stats: ParticipationStatsProvider.Stats?
    ) -> some View {
        StatCard(
            title: "Tasks Done",
            value: stats?.taskEngagement.totalCompleted,
            format: .number,
            symbol: .checkmarkCircleFill,
            accentColor: .accentColor
        )
        if let appEngagement = stats?.appEngagement {
            // TODO verify that this starts counting at 1, ie even if the user only has had the app installed for like 2-3 days!!
            StatCard(
                title: "Current Streak",
                value: appEngagement.currentLaunchAppStreak,
                format: .weekCount,
                symbol: .flameFill,
                accentColor: .orange
            )
            if appEngagement.longestLaunchAppStreak >= 2 {
                StatCard(
                    title: "Longest Streak",
                    value: appEngagement.longestLaunchAppStreak,
                    format: .weekCount,
                    symbol: .trophyFill,
                    accentColor: .yellow
                )
            }
        }
//            StatCard(
//                title: "Active Days",
//                value: stats?.activeDays,
//                format: .number,
//                symbol: .calendarBadgeCheckmark,
//                accentColor: .green,
//                subtitle: stats.map { activeDaysSubtitle(active: $0.activeDays, totalDays: $0.daysSinceEnrollment) }
//            )
        StatCard(
            title: "Surveys Answered",
            value: stats?.taskEngagement.questionnairesCompleted,
            format: .number,
            symbol: .listClipboardFill,
            accentColor: .purple
        )
        StatCard(
            title: "Articles Read",
            value: stats?.taskEngagement.articlesRead,
            format: .number,
            symbol: .bookFill,
            accentColor: .brown
        )
        StatCard(
            title: "ECGs Recorded",
            value: stats?.taskEngagement.ecgsRecorded,
            format: .number,
            symbol: .waveformPathEcgRectangle,
            accentColor: .red
        )
        StatCard(
            title: "Walk / Run Tests",
            value: stats?.taskEngagement.walkRunTestsCompleted,
            format: .number,
            symbol: .figureWalk,
            accentColor: .blue
        )
    }
    
    @ViewBuilder
    private func healthTotalsSection( // swiftlint:disable:this function_body_length
        using stats: ParticipationStatsProvider.HealthStats?
    ) -> some View {
        StatCard(
            title: "Steps",
            value: stats?.totalSteps,
            format: .compactNumber,
            symbol: .figureWalk,
            accentColor: .green
        )
        StatCard(
            title: "Heartbeats",
            value: stats?.totalHeartbeats,
            format: .compactNumber,
            symbol: .heartFill,
            accentColor: .red,
            subtitle: "Estimate"
        )
        StatCard(
            title: "Distance",
            value: stats?.totalDistanceWalkingRunning?.value,
            format: .distance,
            symbol: .mapFill,
            accentColor: .blue
        )
        StatCard(
            title: "Active Energy",
            value: stats?.totalActiveEnergyKcal,
            format: .energyKcal,
            symbol: .flameFill,
            accentColor: .orange
        )
        StatCard(
            title: "Exercise Time",
            value: stats?.totalExerciseTime?.value,
            format: .duration,
            symbol: .figureRun,
            accentColor: .green
        )
        StatCard(
            title: "Sleep",
            value: stats?.totalSleepTime?.value,
            format: .duration,
            symbol: .bedDoubleFill,
            accentColor: .indigo
        )
        StatCard(
            title: "Workouts",
            value: stats?.workoutInfo?.numWorkouts,
            format: .number,
            symbol: .figureCooldown,
            accentColor: .teal
        )
        StatCard(
            title: "Flights Climbed",
            value: stats?.totalFlightsClimbed,
            format: .number,
            symbol: .figureStairs,
            accentColor: .cyan
        )
    }
    
    @ViewBuilder
    private func personalBestsSection(using stats: ParticipationStatsProvider.HealthStats.PersonalBests?) -> some View {
        let dateFormat: Date.FormatStyle = .dateTime.month(.abbreviated).day()
        StatCard(
            title: "Best Step Day",
            value: stats?.bestDailySteps?.value,
            format: .compactNumber,
            symbol: .figureWalk,
            accentColor: .green,
            subtitle: (stats?.bestDailySteps?.date).map { "\($0, format: dateFormat)" }
        )
        StatCard(
            title: "Longest Workout",
            value: stats?.longestWorkout?.duration.value,
            format: .duration,
            symbol: .stopwatchFill,
            accentColor: .blue,
            subtitle: { () -> LocalizedStringResource? in
                let components: [String?] = [
                    stats?.longestWorkout?.date.formatted(dateFormat),
                    stats?.longestWorkout?.activityType.displayTitle.localizedString()
                ]
                let text = components.lazy.compactMap(\.self).joined(separator: " • ")
                return text.isEmpty ? nil : "\(text)"
            }()
        )
        StatCard(
            title: "Max Heart Rate",
            value: stats?.maxHeartRateBPM,
            format: .heartRate,
            symbol: .heartFill,
            accentColor: .red
        )
        StatCard(
            title: "Resting HR",
            value: stats?.avgRestingHeartRateBPM,
            format: .heartRate,
            symbol: .bedDoubleFill,
            accentColor: .pink,
            subtitle: "Average"
        )
    }
    
    @ViewBuilder
    private func funFactsSection() -> some View {
        if let funFacts = makeFunFacts(), !funFacts.isEmpty {
            Section("Fun Facts") {
                ForEach(funFacts) { fact in
                    FunFactCard(fact: fact)
                        .listRowInsets(.zero)
                        .listRowBackground(Color.clear)
                }
            }
        }
    }
}


// MARK: - Helpers

extension ParticipationStatsView {
    private func makeFunFacts() -> [FunFact]? { // swiftlint:disable:this function_body_length discouraged_optional_collection
        // TODO NEED TO LOCALIZE ALL OF THIS HERE!!! (won't be easy bc the substitution placement will differ...)
        guard let stats else {
            return nil
        }
        let healthStats = stats.health
        var facts: [FunFact] = []
        if let steps = healthStats.totalSteps, steps > 0 {
            let distanceKm = healthStats.totalDistanceWalkingRunning?.converted(to: .kilometers).value ?? Double(steps) * 0.000762 // ~0.762m per step
            let distanceFormatted: String = Measurement<UnitLength>(value: distanceKm, unit: .kilometers)
                .converted(to: { () -> UnitLength in
                    switch Locale.current.measurementSystem {
                    case .uk, .us:
                        .miles
                    default: // includes .metric
                        .kilometers
                    }
                }())
                .formatted(.measurement(width: .abbreviated, numberFormatStyle: .number.precision(.fractionLength(0))))
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
        if let beats = healthStats.totalHeartbeats, beats > 0 {
            let lifetimePercent = Double(beats) / 3_000_000_000 // TODO can we simply estimate 3bn lifetime total heartbeats?
            let percentFormatted = lifetimePercent.formatted(.percent.precision(.fractionLength(0...2)))
            facts.append(.init(
                symbol: .heartFill,
                color: .red,
                text: "Your heart has beaten about \(beats.formatted(.number.notation(.compactName))) times since you enrolled \u{2014} roughly \(percentFormatted) of an average lifetime."
            ))
        }
        if let kcal = healthStats.totalActiveEnergyKcal, kcal > 0 {
            let pizzaSlices = Int((kcal / 285).rounded())
            if pizzaSlices > 0 {
                facts.append(.init(
                    symbol: .flameFill,
                    color: .orange,
                    text: "You've burned \(Int(kcal).formatted(.number)) active calories \u{2014} the equivalent of \(pizzaSlices.formatted(.number)) slices of pizza."
                ))
            }
        }
        if let sleepSec = healthStats.totalSleepTime?.value(in: .seconds), sleepSec > TimeConstants.day {
            let days = sleepSec / TimeConstants.day
            facts.append(.init(
                symbol: .bedDoubleFill,
                color: .indigo,
                text: "You've spent about \(days.formatted(.number.precision(.fractionLength(1)))) full days asleep since enrolling. Rest is part of the work."
            ))
        }
        // IDEA re-implement, based on weeks (months?) w/ activity
//        if let active = stats.taskEngagement?.activeDays, let total = engagement?.daysSinceEnrollment, total > 0 {
//            let percent = Double(active) / Double(total)
//            if percent >= 0.7 {
//                facts.append(.init(
//                    symbol: .starFill,
//                    color: .yellow,
//                    text: "You've been active on \(active.formatted(.number)) of \(total.formatted(.number)) days \u{2014} that's a fantastic \(percent.formatted(.percent.precision(.fractionLength(0)))). Keep it up!"
//                ))
//            }
//        }
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
    
    private var nextEnrollmentDurationAchievement: AchievementsManager.UpcomingAchievement? {
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
                Text(numDaysEnrolled > 1 ? "days" : "day")
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
                if let achievement = nextEnrollmentDurationAchievement?.achievement {
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
            .nextLockedAchievements(excluding: nextEnrollmentDurationAchievement.map { [$0.achievement] } ?? [])
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
    let subtitle: LocalizedStringResource?
    let value: Double?
    let format: Format
    let symbol: SFSymbol
    let accentColor: Color
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemSymbol: symbol)
                    .font(.callout)
                    .foregroundStyle(accentColor)
                    .accessibilityHidden(true)
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
    
    init(
        title: LocalizedStringResource,
        value: (some BinaryInteger)?,
        format: Format,
        symbol: SFSymbol,
        accentColor: Color,
        subtitle: LocalizedStringResource? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.value = value.map { Double($0) }
        self.format = format
        self.symbol = symbol
        self.accentColor = accentColor
    }
    
    init(
        title: LocalizedStringResource,
        value: (some BinaryFloatingPoint)?,
        format: Format,
        symbol: SFSymbol,
        accentColor: Color,
        subtitle: LocalizedStringResource? = nil
    ) {
        self.title = title
        self.value = value.map { Double($0) }
        self.format = format
        self.symbol = symbol
        self.accentColor = accentColor
        self.subtitle = subtitle
    }
    
    @ViewBuilder
    private func formattedValue(_ value: Double) -> some View {
        switch format {
        case .number:
            Text(Int(value), format: .number)
        case .compactNumber:
            Text(Int(value), format: .number.notation(.compactName))
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
            let duration: Duration = .seconds(value)
            let formatStyle: Duration.UnitsFormatStyle = .units(
                allowed: duration >= .days(1) ? [.days, .hours] : [.hours, .minutes],
                width: .narrow
            )
            Text(duration, format: formatStyle)
        case .heartRate:
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(Int(value), format: .number)
                Text("bpm").font(.title3.weight(.medium)).foregroundStyle(.secondary)
            }
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
                .accessibilityHidden(true)
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

/// A Button that presents a sheet with the participation stats & achievements.
///
/// - Note: This button is only functional if there exists at least one study enrollment.
///     Otherwise, the button will be disabled and not do anything.
struct ParticipationStatsButton: View {
    // Important: we currently assume that there is only ever at most one enrollment, and that that enrollment will always be the MHC one.
    // this is correct currently, bc we don't have sub-studies yet, but might change at some point down the road.
    @StudyManagerQuery private var enrollments: [StudyEnrollment]
    @State private var showStats = false
    
    private var enrollment: StudyEnrollment? {
        enrollments.first
    }
    
    var body: some View {
        Button {
            showStats = true
        } label: {
            Label(symbol: .medalStar) {
                Text("Stats and Achievements")
            }
        }
        .disabled(enrollment == nil)
        .sheet(isPresented: $showStats) {
            if let enrollment {
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
