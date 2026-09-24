//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import HealthKit
@testable import MyHeartCounts
import SFSafeSymbols
import SpeziHealthKitUI
import Testing


@Suite
struct AchievementStatsTests {
    @Test
    func dailyThresholdsCombineHourlyBucketsWithoutCombiningDays() throws {
        let request = try #require(AchievementsManager.dailyStepsRequest(since: date(0), now: date(49), calendar: calendar()))
        #expect(request.timeRange == date(0)..<date(72))
        let samples = try request.process([
            StatsDocument(metric: "steps", entriesBySourceId: [
                "com.apple.HealthKit": [bucket(hour: 0, count: 6_000), bucket(hour: 1, count: 5_000), bucket(hour: 24, count: 9_000)]
            ])
        ]).elements
        #expect(samples.map { $0.value(as: .count()) } == [11_000, 9_000])
        #expect(samples.map(\.endDate) == [date(24), date(48)])
        let goals = [achievement(.dailyStepCount, target: 10_000), achievement(.dailyStepCount, target: 20_000)]
        var state = AchievementsManager.State()
        state.recordDailySteps(samples, allAchievements: goals)
        #expect(unlockDate(goals[0], in: state) == date(0))
        #expect(unlockDate(goals[1], in: state) == nil)
        #expect(state.state(of: goals[1]).progress == 0.55)
    }

    @Test
    func dailyThresholdsRejectUnalignedBucketsAndFutureEnrollment() throws {
        #expect(AchievementsManager.dailyStepsRequest(since: date(1), now: date(0), calendar: calendar()) == nil)
        let request = try #require(AchievementsManager.dailyStepsRequest(since: date(0), now: date(49), calendar: calendar()))
        let crossingMidnight = StatsDocument.Entry.aggregate(.init(
            start: date(23).addingTimeInterval(1_800), end: date(24).addingTimeInterval(1_800), unit: .count(), values: .sum(20_000)
        ))
        #expect(throws: StatsStore.Processor.Error.self) {
            try request.process([StatsDocument(metric: "steps", entriesBySourceId: ["com.apple.HealthKit": [crossingMidnight]])])
        }
    }

    @Test
    func lowerBackfilledValuesAdvanceEachQualifyingUnlockWithoutLosingBestProgress() throws {
        let goals = [10_000, 20_000, 30_000, 40_000].map { achievement(.dailyStepCount, target: Double($0)) }
        var state = AchievementsManager.State()
        state.record(.dailyStepCount, value: 30_000, timestamp: date(96), allAchievements: goals)
        state.record(.dailyStepCount, value: 15_000, timestamp: date(24), allAchievements: goals)
        state.record(.dailyStepCount, value: 25_000, timestamp: date(48), allAchievements: goals)
        #expect(goals.map { unlockDate($0, in: state) } == [date(24), date(48), date(96), nil])
        #expect(state.state(of: goals[3]).progress == 0.75)
        let restored = try JSONDecoder().decode(AchievementsManager.State.self, from: JSONEncoder().encode(state))
        #expect(restored == state)
    }

    @Test
    func downwardThresholdsAlsoUseTheEarliestQualifyingObservation() {
        let metric = Achievement.Metric(id: "decreasing", rule: .atMost(base: 100))
        let goals = [achievement(metric, target: 70), achievement(metric, target: 50)]
        var state = AchievementsManager.State()
        state.record(metric, value: 40, timestamp: date(96), allAchievements: goals)
        state.record(metric, value: 60, timestamp: date(24), allAchievements: goals)
        #expect(unlockDate(goals[0], in: state) == date(24))
        #expect(unlockDate(goals[1], in: state) == date(96))
    }

    @Test
    func electrocardiogramMilestonesUseNthRecordingDatesAndRemainUnlockedAfterDeletion() {
        let goals = [1, 2, 3, 5].map { achievement(.numRecordedECGs, target: Double($0)) }
        let samples = [ecg(hour: 3), ecg(hour: 1), ecg(hour: 2)]
        var state = AchievementsManager.State()
        state.recordElectrocardiograms(samples, allAchievements: goals)
        #expect(goals.map { unlockDate($0, in: state) } == [date(1), date(2), date(3), nil])
        state.recordElectrocardiograms(samples + [ecg(hour: 0)], allAchievements: goals)
        #expect(goals.map { unlockDate($0, in: state) } == [date(0), date(1), date(2), nil])
        #expect(state.state(of: goals[3]).progress == 0.8)
        let beforeDeletion = state
        state.recordElectrocardiograms([], allAchievements: goals)
        #expect(state == beforeDeletion)
    }

    @Test
    @MainActor
    func weeklyEnrollmentMilestoneIsRegisteredWithItsStableIdentity() throws {
        let manager = AchievementsManager()
        Achievement.registerDefaultAchievements(with: manager)
        let milestone = try #require(manager.achievements.first { $0.id == "participation-streak-1-weekOfYear" })
        #expect(milestone.subcategory == .enrollmentDuration)
        var state = AchievementsManager.State()
        state.record(.enrollmentDurationInDays, value: 7, timestamp: date(0), allAchievements: manager.achievements)
        #expect(unlockDate(milestone, in: state) == nil)
        state.record(.enrollmentDurationInWeeks, value: 1, timestamp: date(24), allAchievements: manager.achievements)
        #expect(unlockDate(milestone, in: state) == date(24))
    }

    @Test
    @MainActor
    func logoutClearsProgressAndRejectsFurtherRecording() async throws {
        let manager = AchievementsManager()
        let goal = achievement(.dailyStepCount, target: 10_000)
        manager.register(achievement: goal)
        manager.record(.dailyStepCount, value: 20_000, timestamp: date(0))
        #expect(manager.didUnlock(goal))
        manager.disassociateFromAccount()
        manager.record(.dailyStepCount, value: 30_000, timestamp: date(24))
        // Let the cancelled debounce task resume; it must not restart synchronization.
        try await Task.sleep(for: .milliseconds(10))
        #expect(manager.systemAvailability == .unavailable(.noUser))
        #expect(!manager.didUnlock(goal))
        #expect(manager.unlockProgress(of: goal) == 0)
    }

    private func achievement(_ metric: Achievement.Metric, target: Double) -> Achievement {
        Achievement(
            id: "\(metric.id)-\(target)",
            category: .init(id: "test", title: "Test"),
            subcategory: nil,
            kind: .threshold(metric: metric, target: target),
            title: "Test",
            description: "Test",
            symbol: .heart,
            visibility: .always
        )
    }

    private func unlockDate(_ achievement: Achievement, in state: AchievementsManager.State) -> Date? {
        if case let .unlocked(date) = state.state(of: achievement) {
            date
        } else {
            nil
        }
    }

    private func date(_ hour: Int) -> Date {
        Date(timeIntervalSince1970: 1_785_542_400 + Double(hour) * 3_600)
    }

    private func calendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }

    private func bucket(hour: Int, count: Double) -> StatsDocument.Entry {
        .aggregate(.init(start: date(hour), end: date(hour + 1), unit: .count(), values: .sum(count)))
    }

    private func ecg(hour: Int) -> ElectrocardiogramStatsSample {
        ElectrocardiogramStatsSample(id: "\(hour)", date: date(hour).addingTimeInterval(-30), endDate: date(hour))
    }
}
