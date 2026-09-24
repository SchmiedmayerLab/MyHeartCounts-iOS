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
struct StatsEventProcessingTests {
    private let healthKit = "com.apple.HealthKit"
    private var range: Range<Date> { date(0)..<date(24) }

    @Test
    func workoutsRetainActiveDurationAcrossMonthsAndResolveCompetingSources() throws {
        let workout = workout(id: "shared", hour: 1)
        let output = try StatsStore.Request.workouts(in: .init(range)).process([
            document(.workouts, [healthKit: [workout]]),
            document(.workouts, ["mirror": [workout], healthKit: [self.workout(id: "second", hour: 3)]])
        ])
        #expect(output.elements.map(\.id) == ["shared", "second"])
        #expect(output.elements.first?.duration == 900)
        #expect(output.elements.first?.endDate == date(2))
        #expect(output.elements.first?.activityType == .walking)
        #expect(output.contributingSourceIDs == [healthKit])
        #expect(output.diagnostics.count == 1)
    }

    @Test
    func recordingsRequireBothEndpointsInsideTheHalfOpenRange() throws {
        let recordings: [StatsDocument.Entry] = [
            ecg(id: "before", hour: -1), ecg(id: "inside", hour: 0), ecg(id: "after", hour: 24),
            .electrocardiogram(.init(id: "at-end", date: date(23), endDate: date(24))),
            .electrocardiogram(.init(id: "incomplete", date: date(23), endDate: date(25)))
        ]
        let output = try StatsStore.Request.electrocardiograms(in: .init(range)).process([
            document(.electrocardiograms, [healthKit: recordings])
        ])
        #expect(output.elements.map(\.id) == ["inside"])
        #expect(output.elements.first?.endDate == date(0).addingTimeInterval(30))
    }

    @Test
    func simultaneousRecordingsCompeteAcrossSources() throws {
        let recordings = document(.electrocardiograms, [healthKit: [ecg(id: "first", hour: 2)], "other": [ecg(id: "second", hour: 2)]])
        let automatic = try StatsStore.Request.electrocardiograms(in: .init(range)).process([recordings])
        #expect(automatic.elements.map(\.id) == ["first"])
        #expect(automatic.diagnostics.count == 1)
        #expect(throws: StatsStore.Processor.Error.self) {
            try StatsStore.Request.electrocardiograms(in: .init(range), sourcePolicy: .mergeCompatible).process([recordings])
        }
        let preferred = try StatsStore.Request.electrocardiograms(in: .init(range), sourcePolicy: .preferred(["other"])).process([recordings])
        #expect(preferred.elements.map(\.id) == ["second"])
        let only = try StatsStore.Request.electrocardiograms(in: .init(range), sourcePolicy: .only("other")).process([recordings])
        #expect(only.elements.map(\.id) == ["second"])
        #expect(only.diagnostics.isEmpty)
    }

    @Test
    func sameSourceRecordingsAndDifferentInstantsRemainDistinctWithoutIdentityDeduplication() throws {
        let output = try StatsStore.Request.electrocardiograms(in: .init(range)).process([
            document(.electrocardiograms, [
                healthKit: [ecg(id: "same-id", hour: 2), ecg(id: "distinct", hour: 2)],
                "other": [ecg(id: "same-id", hour: 3)]
            ])
        ])
        #expect(output.elements.count == 3)
        #expect(output.elements.filter { $0.id == "same-id" }.count == 2)
        #expect(output.elements.filter { $0.date == date(2) }.count == 2)
        #expect(output.contributingSourceIDs == [healthKit, "other"])
        #expect(output.diagnostics.isEmpty)
    }

    @Test
    func malformedEventsAreDiagnosedWithoutDiscardingValidEntries() throws {
        let entries: [StatsDocument.Entry] = [
            workout(id: "", hour: 0),
            .workout(.init(id: "negative-duration", date: date(1), endDate: date(2), duration: -1, activityType: .walking)),
            .workout(.init(id: "infinite-duration", date: date(1), endDate: date(2), duration: .infinity, activityType: .walking)),
            .workout(.init(id: "invalid-end", date: date(2), endDate: date(1), duration: 900, activityType: .walking)),
            .quantity(.init(date: date(3), unit: .second(), value: 900)),
            .aggregate(.init(start: date(3), end: date(4), unit: .second(), values: .sum(900))),
            .electrocardiogram(.init(id: "wrong-event", date: date(3), endDate: date(4))),
            workout(id: "valid", hour: 4)
        ]
        let output = try StatsStore.Request.workouts(in: .init(range)).process([document(.workouts, [healthKit: entries])])
        #expect(output.elements.map(\.id) == ["valid"])
        #expect(output.diagnostics == [.malformedEntryCount(7)])
    }

    @Test
    func quantityRequestsRejectEventPayloadsEvenWhenUnitsAreCompatible() throws {
        let steps = StatsDocument(metric: "steps", entriesBySourceId: [
            healthKit: [ecg(id: "wrong-shape", hour: 2), .quantity(.init(date: date(3), unit: .count(), value: 500))]
        ])
        let output = try StatsStore.Request.quantity(metric: .steps, timeRange: .init(range), aggregationKind: .sum).process([steps])
        #expect(output.elements.map { $0.value(as: .count()) } == [500])
        #expect(output.diagnostics == [.malformedEntryCount(1)])
    }

    private func date(_ hour: Int) -> Date {
        Date(timeIntervalSince1970: 1_788_761_600 + Double(hour) * 3600)
    }

    private func document(_ metric: HealthKitStatsCalculator.MetricID, _ sources: [String: [StatsDocument.Entry]]) -> StatsDocument {
        StatsDocument(metric: metric.rawValue, entriesBySourceId: sources)
    }

    private func workout(id: String, hour: Int) -> StatsDocument.Entry {
        .workout(.init(id: id, date: date(hour), endDate: date(hour + 1), duration: 900, activityType: .walking))
    }

    private func ecg(id: String, hour: Int) -> StatsDocument.Entry {
        .electrocardiogram(.init(id: id, date: date(hour), endDate: date(hour).addingTimeInterval(30)))
    }
}
