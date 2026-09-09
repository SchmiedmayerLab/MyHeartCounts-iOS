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
struct StatsIntervalProcessingTests {
    private let healthKit = "com.apple.HealthKit"
    private var range: Range<Date> { date(0)..<date(24) }

    @Test
    func legacyAveragesFallbackAndReportApproximateIntervalReduction() throws {
        let sources = [healthKit: [bucket(0, amount: 60), bucket(1, amount: 100)], "wearable": [bucket(0, amount: 90)]]
        let result = try StatsStore.Processor.quantity(
            documents: [document(.heartRate, sources)],
            metric: .heartRate,
            timeRange: range,
            aggregationKind: .avg,
            interval: interval(.day)
        )
        #expect(result.elements.first?.value(as: HKUnit.count().unitDivided(by: .minute())) == 80)
        #expect(result.contributingSourceIDs == [healthKit])
        #expect(result.diagnostics.contains(.approximateAverage(timeRange: range)))
        #expect(result.diagnostics.count == 2)
    }

    @Test
    func weightedAveragesRetainWeightsAcrossSourcesAndIntervals() throws {
        let sources = [
            healthKit: [weightedBucket(0, amount: 60, weight: 1), weightedBucket(1, amount: 100, weight: 2)],
            "wearable": [weightedBucket(0, amount: 90, weight: 3)]
        ]
        let result = try StatsStore.Processor.quantity(
            documents: [document(.heartRate, sources)],
            metric: .heartRate,
            timeRange: range,
            aggregationKind: .avg,
            sourcePolicy: .mergeCompatible,
            interval: interval(.day)
        )
        let actual = try #require(result.elements.first?.value(as: HKUnit.count().unitDivided(by: .minute())))
        #expect(abs(actual - 530.0 / 6) < 1e-10)
        #expect(result.diagnostics.isEmpty)
        #expect(result.contributingSourceIDs == [healthKit, "wearable"])
    }

    @Test
    func fullYearOfAlignedHourlySourcesPreservesEveryWeightedBucket() throws {
        let sources = [
            healthKit: (0..<8_760).map { weightedBucket(Double($0), amount: 60, weight: 1) },
            "wearable": (0..<8_760).map { weightedBucket(Double($0), amount: 90, weight: 3) }
        ]
        let result = try StatsStore.Processor.quantity(
            documents: [document(.heartRate, sources)],
            metric: .heartRate,
            timeRange: date(0)..<date(8_760),
            aggregationKind: .avg,
            sourcePolicy: .mergeCompatible,
            interval: interval(.hour)
        )
        #expect(result.elements.count == 8_760)
        #expect(result.elements.first?.startDate == date(0))
        #expect(result.elements.last?.endDate == date(8_760))
        #expect(result.elements.allSatisfy { $0.value(as: HKUnit.count().unitDivided(by: .minute())) == 82.5 })
        #expect(result.contributingSourceIDs == [healthKit, "wearable"])
        #expect(result.diagnostics.isEmpty)
    }

    @Test
    func distantAndFutureAnchorsLocateNearbyIntervals() throws {
        let distant = interval(.hour)
        let range = date(500_000)..<date(500_002)
        #expect(try distant.ranges(covering: range) == [date(500_000)..<date(500_001), date(500_001)..<date(500_002)])
        let future = StatsStore.AggregationInterval(interval: .hour, anchor: date(600_000), calendar: distant.calendar)
        #expect(try future.ranges(covering: range) == distant.ranges(covering: range))
    }

    @Test
    func openEndedRequestsReduceOnlyTheAvailableData() throws {
        let result = try StatsStore.Processor.quantity(
            documents: [document(.heartRate, [healthKit: [bucket(0, amount: 60)]])],
            metric: .heartRate,
            timeRange: .distantPast..<Date.distantFuture,
            aggregationKind: .avg,
            interval: interval(.day)
        )
        #expect(result.elements.count == 1)
        #expect(result.elements.first?.startDate == date(0))
        #expect(result.elements.first?.endDate == date(24))
    }

    @Test
    func calendarIntervalsRetainMonthEndAndDaylightSavingAlignment() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Berlin"))
        let january = try Date("2026-01-31T00:00:00+01:00", strategy: .iso8601)
        let february = try Date("2026-02-28T00:00:00+01:00", strategy: .iso8601)
        let march = try Date("2026-03-31T00:00:00+02:00", strategy: .iso8601)
        let monthly = StatsStore.AggregationInterval(interval: .month, anchor: january, calendar: calendar)
        #expect(try monthly.ranges(covering: january..<march) == [january..<february, february..<march])
        let transitionStart = try Date("2026-03-28T00:00:00+01:00", strategy: .iso8601)
        let daily = StatsStore.AggregationInterval(interval: .day, anchor: transitionStart, calendar: calendar)
        let durations = try daily.ranges(covering: transitionStart..<march).map { $0.upperBound.timeIntervalSince($0.lowerBound) / 3600 }
        #expect(durations == [24, 23, 24])
    }

    @Test
    func finerOrShiftedIntervalsRetainBucketsInsteadOfInventingPrecision() throws {
        let sources = [healthKit: [bucket(0.5, amount: 60)]]
        for interval in [interval(.hour), interval(.init(.init(minute: 30)), alignment: .approximate)] {
            let result = try StatsStore.Processor.quantity(
                documents: [document(.heartRate, sources)],
                metric: .heartRate,
                timeRange: range,
                aggregationKind: .avg,
                interval: interval
            )
            #expect(result.elements.first?.startDate == date(0.5))
            #expect(result.elements.first?.endDate == date(1.5))
            #expect(result.diagnostics == [.unalignedInterval])
        }
    }
}


extension StatsIntervalProcessingTests {
    @Test
    func shiftedTimeZoneBucketsApproximateDailyAndHourlySums() throws {
        let json = #"{"start":"1970-01-02T05:00:00+05:45","end":"1970-01-02T06:00:00+05:45","sum":100,"unit":"count"}"#
        let entry = try JSONDecoder().decode(StatsDocument.Entry.self, from: Data(json.utf8))
        for frequency in [HealthKitStatisticsQuery.AggregationInterval.hour, .day] {
            let result = try StatsStore.Processor.quantity(
                documents: [document(.steps, [healthKit: [entry]])],
                metric: .steps,
                timeRange: date(0)..<date(48),
                aggregationKind: .sum,
                interval: interval(frequency, alignment: .approximate)
            )
            #expect(result.elements.map { $0.value(as: .count()) } == [75, 25])
            #expect(result.diagnostics.filter { if case .approximateInterval = $0 { true } else { false } }.count == 2)
        }
    }

    @Test
    func sevenDayStepsClipBoundaryBucketsAndKeepOnlyPopulatedDays() throws {
        let entries = [sumBucket(-0.5, amount: 100), sumBucket(24, amount: 300), sumBucket(167.5, amount: 200)]
        let result = try StatsStore.Processor.quantity(
            documents: [document(.steps, [healthKit: entries])],
            metric: .steps,
            timeRange: date(0)..<date(168),
            aggregationKind: .sum,
            interval: interval(.day, alignment: .approximate)
        )
        #expect(result.elements.map { $0.value(as: .count()) } == [50, 300, 100])
        #expect(result.elements.map(\.startDate) == [date(0), date(24), date(144)])
        #expect(result.elements.last?.endDate == date(168))
        #expect(result.elements.reduce(0) { $0 + $1.value(as: .count()) } / Double(result.elements.count) == 150)
    }

    @Test
    func strictAlignmentRejectsSplitBucketsAndPartialQueryBounds() {
        for requestedRange in [date(0)..<date(24), date(0.75)..<date(1.5)] {
            for policy in [StatsStore.SourcePolicy.automatic, .mergeCompatible] {
                #expect(throws: StatsStore.Processor.Error.unalignedAggregationInterval) {
                    try StatsStore.Processor.quantity(
                        documents: [document(.heartRate, [healthKit: [bucket(0.5, amount: 60)]])],
                        metric: .heartRate,
                        timeRange: requestedRange,
                        aggregationKind: .avg,
                        sourcePolicy: policy,
                        interval: interval(.hour, alignment: policy == .automatic ? .requireExact : .approximate)
                    )
                }
            }
        }
    }

    @Test
    func approximateAveragesAndExtremaDoNotInventPartialBucketWeights() throws {
        let entries = [weightedBucket(0, amount: 100, weight: 100), weightedBucket(23.5, amount: 60, weight: 1)]
        for kind in [StatisticsAggregationOption.avg, .min, .max] {
            let result = try StatsStore.Processor.quantity(
                documents: [document(.heartRate, [healthKit: entries])],
                metric: .heartRate,
                timeRange: date(0)..<date(48),
                aggregationKind: kind,
                interval: interval(.day, alignment: .approximate)
            )
            let expected: Double = switch kind {
            case .avg: 80
            case .min: 60
            case .max: 100
            case .sum: 0
            }
            #expect(result.elements.map { $0.value(as: HKUnit.count().unitDivided(by: .minute())) } == [expected, 60])
            #expect(result.diagnostics.contains(.approximateInterval(timeRange: date(0)..<date(24))))
        }
    }

    private func date(_ hour: Double) -> Date {
        Date(timeIntervalSince1970: hour * 3600)
    }

    private func document(_ metric: HealthStatsMetric, _ sources: [String: [StatsDocument.Entry]]) -> StatsDocument {
        StatsDocument(metric: metric.id.rawValue, entriesBySourceId: sources)
    }

    private func sumBucket(_ hour: Double, amount: Double, unit: HKUnit = .count()) -> StatsDocument.Entry {
        .aggregate(StatsDocument.Aggregate(start: date(hour), end: date(hour + 1), unit: unit, values: .sum(amount)))
    }

    private func bucket(_ hour: Double, amount: Double, average: StatsDocument.Average? = nil) -> StatsDocument.Entry {
        .aggregate(StatsDocument.Aggregate(
            start: date(hour),
            end: date(hour + 1),
            unit: .count().unitDivided(by: .minute()),
            values: .minMaxAvg(min: amount, max: amount, avg: amount, average: average)
        ))
    }

    private func weightedBucket(_ hour: Double, amount: Double, weight: Double) -> StatsDocument.Entry {
        bucket(hour, amount: amount, average: StatsDocument.Average(numerator: amount * weight, denominator: weight, weighting: "test.temporal.v1"))
    }

    private func interval(
        _ interval: HealthKitStatisticsQuery.AggregationInterval, alignment: StatsStore.AggregationInterval.AlignmentPolicy = .preserveBuckets
    ) -> StatsStore.AggregationInterval {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return StatsStore.AggregationInterval(interval: interval, anchor: date(0), calendar: calendar, alignmentPolicy: alignment)
    }
}
