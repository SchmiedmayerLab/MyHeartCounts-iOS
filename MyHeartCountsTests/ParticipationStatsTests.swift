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
import SpeziHealthKit
import SpeziHealthKitUI
import Testing


@Suite
@MainActor
struct ParticipationStatsTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }

    @Test
    func dailyTotalsPreserveTheCurrentPartialHourAndAvoidDuplicateSources() throws {
        let request = ParticipationStatsProvider.quantityRequest(
            .steps, in: date(0)..<date(24.25), aggregation: .sum, calendar: calendar
        )
        let document = StatsDocument(metric: "steps", entriesBySourceId: [
            "com.apple.HealthKit": [bucket(0, amount: 600), bucket(1, amount: 800), bucket(24, amount: 1_000)],
            "wearable": [bucket(24, amount: 1_000)]
        ])
        let result = try request.process([document])
        #expect(result.elements.map { $0.value(as: .count()) } == [1_400, 1_000])
        #expect(result.contributingSourceIDs == ["com.apple.HealthKit"])
        #expect(ParticipationStatsProvider.bestStepDay(result.elements)?.value == 1_400)
        #expect(ParticipationStatsProvider.bestStepDay(result.elements)?.date == date(0))
    }

    @Test
    func unalignedFallbackCannotBecomeAPersonalBestDay() throws {
        let request = ParticipationStatsProvider.quantityRequest(
            .steps, in: date(0)..<date(24), aggregation: .sum, calendar: calendar
        )
        let entry = StatsDocument.Entry.aggregate(.init(start: date(-12), end: date(36), unit: .count(), values: .sum(2_000)))
        let result = try request.process([StatsDocument(metric: "steps", entriesBySourceId: ["com.apple.HealthKit": [entry]])])
        #expect(result.diagnostics.contains(.unalignedInterval))
        #expect(!ParticipationStatsProvider.isUsable(snapshot(result.elements, diagnostics: result.diagnostics)))
    }

    @Test
    func unknownOrCorruptDataDoesNotBecomeZero() {
        #expect(!ParticipationStatsProvider.isUsable(snapshot([Int]())))
        #expect(!ParticipationStatsProvider.isUsable(snapshot([0], diagnostics: [.invalidDocumentCount(1)])))
        #expect(!ParticipationStatsProvider.isUsable(snapshot([0], diagnostics: [.malformedEntryCount(1)])))
        #expect(ParticipationStatsProvider.isUsable(snapshot([0])))
        #expect(ParticipationStatsProvider.estimatedHeartbeats([], in: date(0)..<date(24)) == nil)
        #expect(ParticipationStatsProvider.sleepSeconds([], in: date(0)..<date(24)) == nil)
        #expect(ParticipationStatsProvider.meanRestingHeartRate([]) == nil)
    }

    @Test
    func heartbeatEstimateClipsBoundariesWithoutFillingMissingHours() {
        let samples = [
            sample(.heartRate, value: 60, start: 0, end: 1),
            sample(.heartRate, value: 120, start: 3, end: 4)
        ]
        // Half of each recorded hour contributes; the two-hour gap contributes nothing.
        #expect(ParticipationStatsProvider.estimatedHeartbeats(samples, in: date(0.5)..<date(3.5)) == 5_400)
    }

    @Test
    func sleepBoundaryClippingRetainsRecordedAsleepDuration() {
        let sessions = [SleepSessionStatsSample(timeRange: date(-4)..<date(4), hoursAsleep: 6)]
        #expect(ParticipationStatsProvider.sleepSeconds(sessions, in: date(0)..<date(24)) == 10_800.0)
        #expect(ParticipationStatsProvider.sleepSeconds(sessions, in: date(-4)..<date(24)) == 21_600.0)
    }

    @Test
    func restingHeartRateAveragesIndividualReadings() {
        let samples = [
            sample(.restingHeartRate, value: 60, start: 0, end: 0),
            sample(.restingHeartRate, value: 90, start: 24, end: 24),
            sample(.restingHeartRate, value: 90, start: 24.5, end: 24.5)
        ]
        #expect(ParticipationStatsProvider.meanRestingHeartRate(samples) == 80)
    }

    @Test
    func bucketedRestingHeartRateCannotBeTreatedAsIndividualReadings() {
        let samples = [
            sample(.restingHeartRate, value: 60, start: 0, end: 0),
            sample(.restingHeartRate, value: 90, start: 1, end: 2)
        ]
        #expect(ParticipationStatsProvider.meanRestingHeartRate(samples) == nil)
    }

    @Test(arguments: [Double.infinity, -.infinity, .nan, .greatestFiniteMagnitude, Double(Int.max), Double(Int.min).nextDown])
    func invalidIntegerValuesAreUnavailable(value: Double) {
        #expect(ParticipationStatsProvider.integerValue(value) == nil)
        #expect(ParticipationStatsProvider.integerValue(value, rounding: .toNearestOrAwayFromZero) == nil)
    }

    @Test
    func validIntegerValuesRetainTheirRoundingRules() {
        #expect(ParticipationStatsProvider.integerValue(42.9) == 42)
        #expect(ParticipationStatsProvider.integerValue(42.9, rounding: .toNearestOrAwayFromZero) == 43)
        #expect(ParticipationStatsProvider.integerValue(Double(Int.min)) == Int.min)
    }

    @Test
    func remoteOverflowCannotProducePersonalBestOrRestingHeartRate() {
        let excessiveSteps = sample(.steps, value: .greatestFiniteMagnitude, start: 0, end: 24)
        #expect(ParticipationStatsProvider.bestStepDay([excessiveSteps]) == nil)
        let excessiveRates = [
            sample(.restingHeartRate, value: .greatestFiniteMagnitude, start: 0, end: 0),
            sample(.restingHeartRate, value: .greatestFiniteMagnitude, start: 1, end: 1)
        ]
        #expect(ParticipationStatsProvider.meanRestingHeartRate(excessiveRates) == nil)
    }

    @Test
    func longestWorkoutUsesActiveDurationInsteadOfWallClockDuration() {
        let workouts = [
            WorkoutStatsSample(id: "paused", date: date(0), endDate: date(2), duration: 1_800, activityType: .walking),
            WorkoutStatsSample(id: "continuous", date: date(3), endDate: date(4), duration: 3_600, activityType: .running)
        ]
        let longest = ParticipationStatsProvider.longestWorkout(workouts)
        #expect(longest?.date == date(3))
        #expect(longest?.activityType == .running)
        #expect(longest?.duration.value == 3_600)
    }

    @Test
    func liveSnapshotsReplaceBackfillAndDeletionWithoutAccumulating() {
        var inputs = ParticipationStatsProvider.HealthSnapshots()
        let range = date(0)..<date(24)
        #expect(inputs.healthStats(in: range).totalSteps == nil)
        inputs.steps = snapshot([sample(.steps, value: 10_000, start: 0, end: 24)])
        inputs.energy = snapshot([sample(.activeEnergy, value: 500, start: 0, end: 24)])
        #expect(inputs.healthStats(in: range).totalSteps == 10_000)
        inputs.steps = snapshot([sample(.steps, value: 3_000, start: 0, end: 24)])
        #expect(inputs.healthStats(in: range).totalSteps == 3_000)
        #expect(inputs.healthStats(in: range).totalActiveEnergyKcal == 500)
        inputs.steps = snapshot([])
        #expect(inputs.healthStats(in: range).totalSteps == nil)
        inputs.energy = nil // A failed metric becomes unavailable independently of the other subscriptions.
        #expect(inputs.healthStats(in: range).totalActiveEnergyKcal == nil)
    }

    @Test
    func liveEventSnapshotsReplaceCountsAndExcludeUnfinishedEvents() {
        var inputs = ParticipationStatsProvider.HealthSnapshots()
        let completed = ElectrocardiogramStatsSample(id: "done", date: date(1), endDate: date(2))
        let unfinished = ElectrocardiogramStatsSample(id: "future", date: date(2), endDate: date(4))
        #expect(inputs.ecgCount(before: date(3)) == nil)
        inputs.ecgs = snapshot([completed, unfinished])
        #expect(inputs.ecgCount(before: date(3)) == 1)
        inputs.ecgs = snapshot([completed, unfinished])
        #expect(inputs.ecgCount(before: date(3)) == 1)
        inputs.ecgs = snapshot([unfinished])
        #expect(inputs.ecgCount(before: date(3)) == 0)
        inputs.workouts = snapshot([
            WorkoutStatsSample(id: "done", date: date(1), endDate: date(2), duration: 600, activityType: .walking),
            WorkoutStatsSample(id: "future", date: date(2), endDate: date(4), duration: 1_000, activityType: .running)
        ])
        let health = inputs.healthStats(in: date(0)..<date(3))
        #expect(health.workoutInfo?.numWorkouts == 1)
        #expect(health.workoutInfo?.totalDuration.value == 600)
        #expect(health.highlights.longestWorkout?.activityType == .walking)
    }

    private func date(_ hour: Double) -> Date {
        Date(timeIntervalSince1970: hour * 3_600)
    }

    private func bucket(_ hour: Double, amount: Double) -> StatsDocument.Entry {
        .aggregate(.init(start: date(hour), end: date(hour + 1), unit: .count(), values: .sum(amount)))
    }

    private func sample(_ metric: HealthStatsMetric, value: Double, start: Double, end: Double) -> QuantitySample {
        QuantitySample(
            id: UUID(),
            sampleType: .healthKit(metric.sampleType),
            unit: metric.sampleType.canonicalUnit,
            value: value,
            startDate: date(start),
            endDate: date(end)
        )
    }

    private func snapshot<Element>(_ elements: [Element], diagnostics: [StatsStore.Diagnostic] = []) -> StatsStore.Snapshot<Element> {
        .init(elements: elements, diagnostics: diagnostics, contributingSourceIDs: [], isFromCache: false, hasPendingWrites: false)
    }
}
