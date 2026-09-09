//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

// swiftlint:disable file_types_order

import Foundation
import HealthKit
import SpeziHealthKit


/// A metric for which the server-side stats documents exist (at `users/{uid}/stats/{metricId}/months/{yyyy-MM}`),
/// and which maps onto a HealthKit quantity sample type displayed in the Health Dashboard.
///
/// See `docs/MHCDataSpec.md` (§User Data Statistics / §Metrics) for the definition of the metrics and the documents' wire format;
/// the write side lives in ``HealthKitStatsCalculator``.
///
/// - Note: this intentionally only models the metrics that map onto `HKQuantitySample`-based dashboard tiles;
///     sleep and blood pressure also have stats documents, but are displayed via dedicated tiles that don't go through
///     the quantity-samples pipeline, and aren't (yet) covered by the stats-documents data source.
struct HealthStatsMetric: Hashable, Sendable {
    static let steps = Self(id: .steps, sampleType: .stepCount)
    static let exerciseTime = Self(id: .exerciseTime, sampleType: .appleExerciseTime)
    static let heartRate = Self(id: .heartRate, sampleType: .heartRate)
    static let weight = Self(id: .weight, sampleType: .bodyMass)
    static let height = Self(id: .height, sampleType: .height)
    static let bmi = Self(id: .bmi, sampleType: .bodyMassIndex)
    
    static let all: [Self] = [.steps, .exerciseTime, .heartRate, .weight, .height, .bmi]
    
    /// The metric's well-known identifier, as used in the stats document paths and the documents' `metric` field.
    let id: HealthKitStatsCalculator.MetricID
    /// The quantity sample type this metric corresponds to.
    let sampleType: SampleType<HKQuantitySample>
    
    private init(id: HealthKitStatsCalculator.MetricID, sampleType: SampleType<HKQuantitySample>) {
        self.id = id
        self.sampleType = sampleType
    }
    
    /// The metric corresponding to a quantity sample type, if one exists.
    init?(_ sampleType: SampleType<HKQuantitySample>) {
        if let metric = Self.all.first(where: { $0.sampleType.id == sampleType.id }) {
            self = metric
        } else {
            return nil
        }
    }
}


/// A single sleep session from the `sleep` metric's stats documents.
struct SleepSessionStatsSample: Hashable, Sendable {
    /// the session's bounds
    let timeRange: Range<Date>
    /// the time spent asleep during the session, in hours
    let hoursAsleep: Double
}


/// A single blood pressure reading from the `blood-pressure` metric's stats documents.
struct BloodPressureStatsSample: Hashable, Sendable {
    let date: Date
    let systolic: Double
    let diastolic: Double
    
    var timeRange: Range<Date> {
        date..<date
    }
}
