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
        /// The month's individual readings (see ``isIndividualReading(_:)``), stored under the ``MetricID/bloodGlucose`` metric.
        let readings: [StatsDocument.BloodGlucose]
        /// Hourly min/max/avg aggregates of the month's other readings, stored under the ``MetricID/bloodGlucoseHourly`` metric.
        let hourly: [StatsDocument.Aggregate]
    }

    /// Whether a blood glucose sample is an individual reading, which we store as-is.
    ///
    /// Individual readings are the ones the participant entered by hand, and the ones tagged with their meal time.
    /// All other readings are stored as hourly aggregates: continuous glucose monitors record a reading every few minutes,
    /// which would be too many entries for a monthly stats document.
    static func isIndividualReading(_ sample: HKQuantitySample) -> Bool {
        sample.metadata?[HKMetadataKeyWasUserEntered] as? Bool == true || sample.metadata?[HKMetadataKeyBloodGlucoseMealTime] != nil
    }

    /// Splits a month's blood glucose samples into individual readings and hourly aggregates.
    ///
    /// - parameter monthStart: the start of the month; the hourly buckets are anchored there, as they are for HealthKit's statistics queries.
    static func bloodGlucoseEntries(for samples: [HKQuantitySample], monthStart: Date) -> BloodGlucoseEntries {
        let unit = SampleType.bloodGlucose.canonicalUnit // mg/dL
        var readings: [StatsDocument.BloodGlucose] = []
        var valuesByHour: [Date: [Double]] = [:]
        for sample in samples {
            let value = sample.quantity.doubleValue(for: unit)
            if isIndividualReading(sample) {
                let mealTime: StatsDocument.BloodGlucose.MealTime? = switch (sample.metadata?[HKMetadataKeyBloodGlucoseMealTime] as? NSNumber)
                    .flatMap({ HKBloodGlucoseMealTime(rawValue: $0.intValue) }) {
                case .preprandial: .beforeMeal
                case .postprandial: .afterMeal
                case nil: nil
                @unknown default: nil
                }
                readings.append(StatsDocument.BloodGlucose(
                    date: sample.startDate,
                    unit: unit,
                    value: value,
                    mealTime: mealTime,
                    isUserEntered: sample.metadata?[HKMetadataKeyWasUserEntered] as? Bool == true
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
