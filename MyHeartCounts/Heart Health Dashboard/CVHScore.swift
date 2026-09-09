//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Algorithms
import Foundation
import HealthKit
import MyHeartCountsShared
import SpeziAccount
import SpeziFoundation
import SpeziHealthKit
import SpeziHealthKitUI
import SwiftUI


@MainActor
@propertyWrapper
struct CVHScore: DynamicProperty {
    protocol ComponentSampleProtocol {
        var timeRange: Range<Date> { get }
    }
    
    enum PreferredExerciseMetric {
        case exerciseMinutes
        case stepCount
    }
    
    var preferredExerciseMetric: PreferredExerciseMetric {
        switch (!statsExerciseTime.isEmpty, !statsStepCount.isEmpty) {
        case (true, _), (false, false):
            return .exerciseMinutes
        case (false, true):
            return .stepCount
        }
    }
    
    @Environment(Account.self)
    private var account: Account?
    
    @MHCFirestoreQuery(sampleType: .dietMEPAScore, timeRange: .last(months: 2))
    private var dietScores
    
    @MHCFirestoreQuery(sampleType: .mentalWellbeingScore, timeRange: .last(months: 2))
    private var mentalWellbeingScores
    
    @MHCFirestoreQuery(sampleType: .bloodLipids, timeRange: .last(months: 2))
    private var bloodLipids
    
    @MHCFirestoreQuery(sampleType: .nicotineExposure, timeRange: .last(months: 2))
    private var nicotineExposure
    
    // NOTE: blood glucose is the one remaining HealthKit-queried score input: it has no stats-documents metric
    // (it is planned to move to the custom fasting/A1c quantity sample types, which will live directly in firestore).
    @HealthKitQuery(.bloodGlucose, timeRange: .last(days: 14))
    private var bloodGlucose
    
    // MARK: server-side stats documents
    // (the dashboard's sole data source for the HealthKit-derived metrics; see `StatsDocumentsQuery`.)
    
    @StatsDocumentsQuery<QuantitySample>(metric: .exerciseTime, timeRange: .last(days: 7).offset(by: .init(day: -1)), aggregationKind: .sum)
    private var statsExerciseTime
    
    @StatsDocumentsQuery<QuantitySample>(
        metric: .steps,
        timeRange: .last(days: 7).offset(by: .init(day: -1)),
        aggregationKind: .sum,
        interval: .init(
            interval: .day,
            anchor: Calendar.current.startOfDay(for: .now),
            calendar: .current,
            alignmentPolicy: .approximate
        )
    )
    private var statsStepCount
    
    @StatsDocumentsQuery<SleepSessionStatsSample>(sleepSessionsIn: .last(days: 14))
    private var statsSleepSessions
    
    @StatsDocumentsQuery<QuantitySample>(metric: .bmi, timeRange: .last(days: 14), aggregationKind: .avg)
    private var statsBodyMassIndex
    
    @StatsDocumentsQuery<QuantitySample>(metric: .weight, timeRange: .last(months: 3), aggregationKind: .avg)
    private var statsBodyWeight
    
    // the most recent height, however old: adults don't grow, and the stats documents cover the month of the latest
    // height sample even when it predates both enrollment and the chart history.
    @StatsDocumentsQuery<QuantitySample>(metric: .height, timeRange: .ever, aggregationKind: .avg)
    private var statsHeight
    
    @StatsDocumentsQuery<BloodPressureStatsSample>(bloodPressureIn: .last(months: 3))
    private var statsBloodPressure
    
    
    /// the composite CVH score, in the range of `0...1`. `nil` if there aren't enough input values to compute a score
    var wrappedValue: Double? {
        let scores: [ScoreResult] = Array {
            dietScore
            switch preferredExerciseMetric {
            case .exerciseMinutes:
                physicalExerciseScore
            case .stepCount:
                stepCountScore
            }
            nicotineExposureScore
            sleepHealthScore
            bodyMassIndexScore
            bloodLipidsScore
            bloodGlucoseScore
            bloodPressureScore
        }
        let scoreResults = scores.compactMap { $0.score.map { $0.clamped(to: 0...1) } }
        return scoreResults.count < 5 ? nil : scoreResults.reduce(0, +) / Double(scoreResults.count)
    }
    
    var projectedValue: Self {
        self
    }
}


extension CVHScore {
    var dietScore: ScoreResult {
        ScoreResult(
            "Most Recent Score",
            sampleType: .custom(.dietMEPAScore),
            sample: dietScores.first,
            value: { $0.value(as: $0.sampleType.displayUnit) },
            definition: .cvhDiet
        )
    }
    
    var physicalExerciseScore: ScoreResult {
        ScoreResult(
            "Last \(7) Days",
            sampleType: .healthKit(.quantity(.appleExerciseTime)),
            timeRange: HealthKitQueryTimeRange.last(days: 7).offset(by: .init(day: -1)).range,
            input: statsExerciseTime.isEmpty ? nil : statsExerciseTime,
            value: { samples in samples.reduce(0) { $0 + $1.value(as: .minute()) } },
            definition: .cvhPhysicalExercise
        )
    }
    
    var stepCountScore: ScoreResult {
        let avgText: LocalizedStringResource = "Daily Average"
        let timeRangeText: LocalizedStringResource = "Last \(7) Days"
        // The query returns daily sums. Average only days with data, preserving the score's denominator.
        let timeRange = HealthKitQueryTimeRange.last(days: 7).offset(by: .init(day: -1)).range
        // A coarser source cannot supply daily inputs; never interpret retained raw buckets as days.
        let hasDailySums = !statsStepCount.isEmpty && $statsStepCount.snapshot?.diagnostics.contains(.unalignedInterval) == false
        return ScoreResult(
            "\(avgText), \(timeRangeText)",
            sampleType: .healthKit(.quantity(.stepCount)),
            timeRange: timeRange,
            input: hasDailySums ? statsStepCount : nil,
            value: { $0.map { $0.value(as: .count()) }.mean()?.rounded() },
            definition: .cvhStepCount
        )
    }
    
    var nicotineExposureScore: ScoreResult {
        ScoreResult(
            "Most Recent Response",
            sampleType: .custom(.nicotineExposure),
            sample: nicotineExposure.first,
            value: { NicotineExposureCategoryValues(rawValue: Int($0.value(as: $0.sampleType.displayUnit))) },
            definition: .cvhNicotine
        )
    }
    
    var mentalHealthScore: ScoreResult {
        ScoreResult(
            "Most Recent Response",
            sampleType: .custom(.mentalWellbeingScore),
            sample: mentalWellbeingScores.first,
            value: { $0.value(as: $0.sampleType.displayUnit) * 4 },
            definition: .cvhMentalWellbeing
        )
    }
    
    var sleepHealthScore: ScoreResult {
        // the sleep stats documents store one entry per sleep session, with the value being the time asleep in hours
        if let mostRecentSession = statsSleepSessions.last {
            ScoreResult(
                "Most Recent Night",
                sampleType: .healthKit(.category(.sleepAnalysis)),
                sample: mostRecentSession,
                value: { $0.hoursAsleep },
                definition: .cvhSleep
            )
        } else {
            ScoreResult(
                "Last Night",
                sampleType: .healthKit(.category(.sleepAnalysis)),
                definition: .cvhSleep
            )
        }
    }
    
    var bodyMassIndexScore: ScoreResult {
        let def = { () -> ScoreDefinition in
            guard let ethnicitySelection = account?.details?.raceEthnicity else {
                return .cvhBMI
            }
            let isAsian = ethnicitySelection.overlaps([.asianIndian, .chinese, .filipino, .japanese, .korean, .vietnamese, .pacificIslander])
            return isAsian ? .cvhBMIAsian : .cvhBMI
        }()
        let title: LocalizedStringResource = "Most Recent Sample"
        let sampleType = MHCSampleType.healthKit(.quantity(.bodyMassIndex))
        // when the stats-documents source is active, we convert its samples into (fake) HKQuantitySamples,
        // which lets the source-independent selection/fallback logic below stay unchanged
        // the stats samples get converted into (fake) HKQuantitySamples, which lets the
        // source-independent selection/fallback logic below operate on them directly
        let bmiSample = statsBodyMassIndex.max(by: \.endDate)?.asHKQuantitySample(of: SampleType.bodyMassIndex)
        let weightSample = statsBodyWeight.max(by: \.endDate)?.asHKQuantitySample(of: SampleType.bodyMass)
        let heightSample = statsHeight.max(by: \.endDate)?.asHKQuantitySample(of: SampleType.height)
        func calcBMI(weight: HKQuantity, height: HKQuantity) -> Double {
            weight.doubleValue(for: .gramUnit(with: .kilo)) / pow(height.doubleValue(for: .meter()), 2)
        }
        func makeScore(bmiSample: HKQuantitySample) -> ScoreResult {
            ScoreResult(
                title,
                sampleType: sampleType,
                sample: bmiSample,
                value: { $0.quantity.doubleValue(for: SampleType.bodyMassIndex.displayUnit) },
                definition: def
            )
        }
        func makeScore(fromWeight weight: HKQuantitySample, height: HKQuantitySample) -> ScoreResult {
            let fakeSample = HKQuantitySample(
                type: SampleType.bodyMassIndex.hkSampleType,
                quantity: HKQuantity(
                    unit: SampleType.bodyMassIndex.displayUnit,
                    doubleValue: calcBMI(weight: weight.quantity, height: height.quantity)
                ),
                start: weight.endDate > height.endDate ? weight.startDate : height.startDate,
                end: weight.endDate > height.endDate ? weight.endDate : height.endDate
            )
            return makeScore(bmiSample: fakeSample)
        }
        switch (bmiSample, weightSample, heightSample) {
        case (nil, nil, nil), (nil, .some, nil), (nil, nil, .some):
            // if there are no samples, return nil
            return .init(title, sampleType: sampleType, definition: def)
        case (.some(let sample), nil, nil), (.some(let sample), .some, nil), (.some(let sample), nil, .some):
            // if we have a BMI sample, but not also a weight AND height sample, return the BMI sample
            return makeScore(bmiSample: sample)
        case let (nil, .some(weight), .some(height)):
            // if we have no BMI sample, but weight and height samples, compute BMI from that
            guard Date.now.timeIntervalSince(weight.endDate) < TimeConstants.year / 2 else {
                // if the weight is from too long ago, we don't use it.
                // we don't have the same check for height, since that doesn't flucuate as much as weight, for adults.
                return .init(title, sampleType: sampleType, definition: def)
            }
            return makeScore(fromWeight: weight, height: height)
        case let (.some(bmi), .some(weight), .some(height)):
            if bmi.endDate > weight.endDate {
                // if the BMI sample is newer, use that
                return makeScore(bmiSample: bmi)
            } else {
                return makeScore(fromWeight: weight, height: height)
            }
        }
    }
    
    var bloodLipidsScore: ScoreResult {
        ScoreResult(
            "Most Recent Sample",
            sampleType: .custom(.bloodLipids),
            sample: bloodLipids.first,
            value: { $0.value(as: $0.sampleType.displayUnit) },
            definition: .cvhBloodLipids
        )
    }
    
    var bloodGlucoseScore: ScoreResult {
        ScoreResult(
            "Most Recent Sample",
            sampleType: .healthKit(.quantity(.bloodGlucose)),
            sample: bloodGlucose.last,
            value: { $0.quantity.doubleValue(for: SampleType.bloodGlucose.displayUnit) },
            definition: .cvhBloodGlucose
        )
    }
    
    var bloodPressureScore: ScoreResult {
        ScoreResult(
            "Most Recent Sample",
            sampleType: .healthKit(.correlation(.bloodPressure)),
            sample: statsBloodPressure.last,
            value: { sample in
                BloodPressureMeasurement(systolic: Int(sample.systolic), diastolic: Int(sample.diastolic))
            },
            definition: .cvhBloodPressure
        )
    }
}


extension HealthKitQueryTimeRange {
    func offset(by components: DateComponents, in cal: Calendar = .current) -> Self {
        guard let start = cal.date(byAdding: components, to: range.lowerBound),
              let end = cal.date(byAdding: components, to: range.upperBound) else {
            fatalError("Unable to compute date range")
        }
        return .init(start..<end)
    }
}


extension QuantitySample: CVHScore.ComponentSampleProtocol {}
extension BloodPressureStatsSample: CVHScore.ComponentSampleProtocol {}
extension SleepSessionStatsSample: CVHScore.ComponentSampleProtocol {}

extension QuantitySample {
    /// Converts the sample into an (unsaved) `HKQuantitySample` of the specified type.
    /// (NOTE: `SampleType` needs to be qualified here: in this extension's scope, it'd otherwise resolve to `QuantitySample.SampleType`.)
    fileprivate func asHKQuantitySample(of sampleType: SpeziHealthKit.SampleType<HKQuantitySample>) -> HKQuantitySample {
        HKQuantitySample(
            type: sampleType.hkSampleType,
            quantity: hkQuantity(),
            start: startDate,
            end: endDate
        )
    }
}

extension HKQuantitySample: CVHScore.ComponentSampleProtocol {}


extension HealthKit.SourceFilter {
    static let appleHealthSystem = Self.bundleId(beginsWith: "com.apple.health")
}


extension CVHScore {
    static var sleepDataSourceFilter: HealthKit.SourceFilter {
        LaunchOptions.launchOptions[Self.considerAllSleepDataLaunchOption] ? .any : .appleHealthSystem
    }
    
    private static let considerAllSleepDataLaunchOption = LaunchOption<Bool>("--dashboardConsiderAllSleepData", default: false)
}
