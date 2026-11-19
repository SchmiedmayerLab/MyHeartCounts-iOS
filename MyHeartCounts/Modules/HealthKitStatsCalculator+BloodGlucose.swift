//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveHealthKit
import HealthKit


extension HealthKitStatsCalculator {
    /// The stats document entries for one month of blood glucose samples.
    struct BloodGlucoseEntries {
        /// The month's individual readings, stored under the ``MetricID/bloodGlucose`` metric.
        let readings: [StatsDocument.BloodGlucose]
        /// Hourly min/max/avg aggregates of the month's continuous readings, stored under the ``MetricID/bloodGlucoseHourly`` metric.
        let hourly: [StatsDocument.Aggregate]
    }
    
    private struct DailySource: Hashable {
        let source: String
        let day: Date
    }

    /// The number of blood glucose readings per day above which a source counts as continuously recording.
    ///
    /// Continuous glucose monitors record a reading every few minutes (≈ 288 per day); people measuring by hand
    /// (e.g. with a finger-prick meter) take a few readings a day.
    static let continuousGlucoseReadingsPerDay = 24

    /// Splits a month's blood glucose samples into individual readings and hourly aggregates.
    ///
    /// A reading is stored individually, unless it comes from a source that recorded more than
    /// ``continuousGlucoseReadingsPerDay`` readings on some day of the month (i.e., a continuous glucose monitor):
    /// those would be too many entries for a monthly stats document, and are stored as hourly aggregates instead.
    /// Readings entered by hand or tagged with their meal time are always stored individually.
    ///
    /// - parameter monthStart: the start of the month; the hourly buckets are anchored there, as they are for HealthKit's statistics queries.
    static func bloodGlucoseEntries(for samples: [HKQuantitySample], monthStart: Date, calendar: Calendar = .current) -> BloodGlucoseEntries {
        let unit = SampleType.bloodGlucose.canonicalUnit // mg/dL
        let continuousSources = Set(
            Dictionary(grouping: samples) { sample in
                DailySource(source: sample.sourceRevision.source.bundleIdentifier, day: calendar.startOfDay(for: sample.startDate))
            }
            .filter { $0.value.count > continuousGlucoseReadingsPerDay }
            .map(\.key.source)
        )
        var readings: [StatsDocument.BloodGlucose] = []
        var valuesByHour: [Date: [Double]] = [:]
        for sample in samples {
            let value = sample.quantity.doubleValue(for: unit)
            let mealTime = (sample.metadata?[HKMetadataKeyBloodGlucoseMealTime] as? Int).flatMap(HKBloodGlucoseMealTime.init(rawValue:))
            let isUserEntered = sample.metadata?[HKMetadataKeyWasUserEntered] as? Bool == true
            if isUserEntered || mealTime != nil || !continuousSources.contains(sample.sourceRevision.source.bundleIdentifier) {
                readings.append(StatsDocument.BloodGlucose(
                    date: sample.startDate,
                    unit: unit,
                    value: value,
                    mealTime: mealTime.flatMap(StatsDocument.BloodGlucose.MealTime.init),
                    isUserEntered: isUserEntered
                ))
            } else {
                let hourIndex = (sample.startDate.timeIntervalSince(monthStart) / TimeConstants.hour).rounded(.down)
                valuesByHour[monthStart.addingTimeInterval(hourIndex * TimeConstants.hour), default: []].append(value)
            }
        }
        let hourly = valuesByHour.sorted { $0.key < $1.key }.compactMap { start, values -> StatsDocument.Aggregate? in
            guard let min = values.min(), let max = values.max() else {
                return nil
            }
            return StatsDocument.Aggregate(
                start: start,
                end: start.addingTimeInterval(TimeConstants.hour),
                unit: unit,
                // the readings' arithmetic mean
                values: .minMaxAvg(min: min, max: max, avg: values.reduce(0, +) / Double(values.count))
            )
        }
        return BloodGlucoseEntries(readings: readings.sorted { $0.date < $1.date }, hourly: hourly)
    }
}


extension StatsDocument.BloodGlucose.MealTime {
    init?(_ mealTime: HKBloodGlucoseMealTime) {
        switch mealTime {
        case .preprandial:
            self = .beforeMeal
        case .postprandial:
            self = .afterMeal
        @unknown default:
            return nil
        }
    }
}
