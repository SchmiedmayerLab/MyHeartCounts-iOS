//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Algorithms
import Foundation
import GroveAccount
import GroveFoundation
import GroveHealthKit
import GroveHealthKitUI
import HealthKit
import MyHeartCountsShared
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
        switch (weeklyExerciseTime.isEmpty, dailyStepCount.isEmpty) {
        case (false, _), (true, true):
            .exerciseMinutes
        case (true, false):
            .stepCount
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
    
    @HealthKitStatisticsQuery(
        .appleExerciseTime,
        aggregatedBy: [.sum],
        over: .init(.init(day: 7)),
        timeRange: .last(days: 7).offset(by: .init(day: -1))
    )
    private var weeklyExerciseTime
    
    @HealthKitStatisticsQuery(
        .stepCount,
        aggregatedBy: [.sum],
        over: .day,
        timeRange: .last(days: 7).offset(by: .init(day: -1))
    )
    private var dailyStepCount
    
    @SleepSessionsQuery(timeRange: .last(days: 14), source: Self.sleepDataSourceFilter)
    private var sleepSessions
    
    @HealthKitQuery(.bodyMassIndex, timeRange: .last(days: 14))
    private var bodyMassIndex
    
    @HealthKitQuery(.bodyMass, timeRange: .last(months: 3))
    private var bodyWeight
    
    @HealthKitQuery(.height, timeRange: .last(years: 5))
    private var height
    
    @HealthKitQuery(.bloodGlucose, timeRange: .last(days: 14))
    private var bloodGlucose
    
    @HealthKitQuery(.bloodPressure, timeRange: .last(months: 3))
    private var bloodPressure
    
    
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
            value: \.value,
            definition: .cvhDiet
        )
    }
    
    var physicalExerciseScore: ScoreResult {
        ScoreResult(
            "Last \(7) Days",
            sampleType: .healthKit(.quantity(.appleExerciseTime)),
            sample: weeklyExerciseTime.last,
            value: { $0.sumQuantity()?.doubleValue(for: .minute()) ?? 0 },
            definition: .cvhPhysicalExercise
        )
    }
    
    var stepCountScore: ScoreResult {
        let avgText: LocalizedStringResource = "Daily Average"
        let timeRangeText: LocalizedStringResource = "Last \(7) Days"
        return ScoreResult(
            "\(avgText), \(timeRangeText)",
            sampleType: .healthKit(.quantity(.stepCount)),
            timeRange: $dailyStepCount.timeRange.range,
            input: dailyStepCount,
            value: { $0.compactMap { $0.sumQuantity()?.doubleValue(for: .count()) }.mean()?.rounded() },
            definition: .cvhStepCount
        )
    }
    
    var nicotineExposureScore: ScoreResult {
        ScoreResult(
            "Most Recent Response",
            sampleType: .custom(.nicotineExposure),
            sample: nicotineExposure.first,
            value: { NicotineExposureCategoryValues(rawValue: Int($0.value)) },
            definition: .cvhNicotine
        )
    }
    
    var mentalHealthScore: ScoreResult {
        ScoreResult(
            "Most Recent Response",
            sampleType: .custom(.mentalWellbeingScore),
            sample: mentalWellbeingScores.first,
            value: { $0.value * 4 },
            definition: .cvhMentalWellbeing
        )
    }
    
    var sleepHealthScore: ScoreResult {
        if sleepSessions.isEmpty {
            ScoreResult(
                "Last Night",
                sampleType: .healthKit(.category(.sleepAnalysis)),
                definition: .cvhSleep
            )
        } else {
            ScoreResult(
                "Most Recent Night",
                sampleType: .healthKit(.category(.sleepAnalysis)),
                sample: sleepSessions.last,
                value: { $0.totalTimeSpentAsleep / 60 / 60 },
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
        let bmiSample = bodyMassIndex.last
        let weightSample = bodyWeight.last
        let heightSample = height.last
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
            guard weight.endDate.timeIntervalSinceNow < TimeConstants.year / 2 else {
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
            value: \.value,
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
            sample: bloodPressure.last,
            value: { correlation in
                if let systolic = correlation.firstSample(ofType: .bloodPressureSystolic),
                   let diastolic = correlation.firstSample(ofType: .bloodPressureDiastolic) {
                    BloodPressureMeasurement(
                        systolic: Int(systolic.quantity.doubleValue(for: SampleType.bloodPressureSystolic.displayUnit)),
                        diastolic: Int(diastolic.quantity.doubleValue(for: SampleType.bloodPressureDiastolic.displayUnit))
                    )
                } else {
                    nil
                }
            },
            definition: .cvhBloodPressure
        )
    }
}


extension ScoreDefinition {
    static let cvhDiet = ScoreDefinition(default: 0, scoringBands: [
        .inRange(17...21, score: 1, explainer: "17 – 21"),
        .inRange(14...16, score: 0.85, explainer: "14 – 16"),
        .inRange(11...13, score: 0.7, explainer: "11 – 13"),
        .inRange(8...10, score: 0.5, explainer: "8 – 10"),
        .inRange(5...7, score: 0.25, explainer: "5 – 7"),
        .inRange(..<5, score: 0, explainer: "< 5")
    ])
    
    static let cvhMentalWellbeing = ScoreDefinition(
        range: 0...100,
        explainer: .init(footerText: nil, bands: [
            .init(
                leadingText: "\(0)",
                trailingText: "\(100)",
                background: .gradient(
                    // same colors as Gradient.redToGreen, but with different distribution
                    Gradient(stops: [
                        Gradient.Stop(color: .red, location: 0),
                        Gradient.Stop(color: .orange, location: 0.2),
                        Gradient.Stop(color: .yellow, location: 0.5),
                        Gradient.Stop(color: .green, location: 0.8)
                    ])
                )
            )
        ])
    )
    
    static let cvhPhysicalExercise = ScoreDefinition(
        default: 0,
        scoringBands: [
            .inRange(150..., score: 1, explainer: "150 +"),
            .inRange(120..<150, score: 0.9, explainer: "120 – 149"),
            .inRange(90..<120, score: 0.8, explainer: "90 – 119"),
            .inRange(60..<90, score: 0.6, explainer: "60 – 89"),
            .inRange(30..<60, score: 0.4, explainer: "30 – 59"),
            .inRange(1..<30, score: 0.2, explainer: "1 – 29")
        ],
        explainerFooterText: "EXERCISE_MINUTES_SCORE_EXPLAINER"
    )
    
    static let cvhStepCount: ScoreDefinition = {
        let fmtInt = { ($0 as Int).formatted(.number) }
        return ScoreDefinition(default: 0, scoringBands: [
            .inRange(10_000..., score: 1, explainer: "\(fmtInt(10000)) +"),
            .inRange(8_000..<10_000, score: 0.9, explainer: "\(fmtInt(8000)) – \(fmtInt(9999))"),
            .inRange(6_000..<8_000, score: 0.8, explainer: "\(fmtInt(6000)) – \(fmtInt(7999))"),
            .inRange(4_000..<6_000, score: 0.6, explainer: "\(fmtInt(4000)) – \(fmtInt(5999))"),
            .inRange(2_000..<4_000, score: 0.4, explainer: "\(fmtInt(2000)) – \(fmtInt(3999))"),
            .inRange(0..<2_000, score: 0.2, explainer: "< \(fmtInt(2000))")
        ])
    }()
    
    static let cvhNicotine: ScoreDefinition = {
        let makeEntry = { (value: NicotineExposureCategoryValues, score: Double) -> ScoreDefinition.ScoringBand in
            ScoreDefinition.ScoringBand.equal(
                to: value,
                score: score,
                explainerBand: .init(
                    leadingText: value.localizedStringResource,
                    trailingText: "\(Int(score * 100))",
                    background: .color(Gradient.redToGreen.color(at: score))
                )
            )
        }
        return ScoreDefinition(default: 0, scoringBands: [
            makeEntry(.neverSmoked, 1),
            makeEntry(.quitMoreThan5YearsAgo, 0.75),
            makeEntry(.quitWithin1To5Years, 0.5),
            makeEntry(.quitWithinLastYearOrIsUsingNDS, 0.25),
            makeEntry(.activelySmoking, 0)
        ])
    }()
    
    static let cvhSleep = ScoreDefinition(default: 0, scoringBands: [
        .inRange(7..<9, score: 1, explainer: "7 to 9 hours"),
        .inRange(9..<10, score: 0.9, explainer: "9 to 10 hours"),
        .inRange(6..<7, score: 0.7, explainer: "6 to 7 hours"),
        .inRange(5..<6, score: 0.4, explainer: "5 to 6 hours"),
        .inRange(10..., score: 0.4, explainer: "10+ hours"),
        .inRange(4..<5, score: 0.2, explainer: "4 to 5 hours")
    ])
    
    static let cvhBMI: ScoreDefinition = {
        let fmt = { ($0 as Double).formatted(.number.precision(.fractionLength(0...1))) }
        return ScoreDefinition(default: 0, scoringBands: [
            .inRange(..<16, score: 0.4, explainer: "< \(fmt(16)) (Severely underweight)"),
            .inRange(16..<18.5, score: 0.6, explainer: "\(fmt(16)) – \(fmt(18.4)) (Underweight)"),
            .inRange(18.5..<25, score: 1, explainer: "\(fmt(18.5)) – \(fmt(24.9)) (Normal weight)"),
            .inRange(25..<30, score: 0.7, explainer: "\(fmt(25)) – \(fmt(29.9)) (Overweight)"),
            .inRange(30..<35, score: 0.5, explainer: "\(fmt(30)) – \(fmt(34.9)) (Obesity class I)"),
            .inRange(35..<40, score: 0.3, explainer: "\(fmt(35)) – \(fmt(39.9)) (Obesity class II)"),
            .inRange(40..., score: 0.1, explainer: "\(fmt(40))+ (Obesity class III)")
        ])
    }()
    
    static let cvhBMIAsian: ScoreDefinition = {
        let fmt = { ($0 as Double).formatted(.number.precision(.fractionLength(0...1))) }
        return ScoreDefinition(default: 0, scoringBands: [
            .inRange(..<16, score: 0.4, explainer: "< \(fmt(16)) (Severely underweight)"),
            .inRange(16..<18.5, score: 0.6, explainer: "\(fmt(16)) – \(fmt(18.4)) (Underweight)"),
            .inRange(18.5..<23, score: 1, explainer: "\(fmt(18.5)) – \(fmt(22.9)) (Normal weight)"),
            .inRange(23..<25, score: 0.75, explainer: "\(fmt(23)) – \(fmt(24.9)) (Overweight / At risk)"),
            .inRange(25..<30, score: 0.5, explainer: "\(fmt(25)) – \(fmt(29.9)) (Obesity class I)"),
            .inRange(30..., score: 0.2, explainer: "\(fmt(30))+ (Obesity class II)")
        ])
    }()
    
    /// LDL Cholesterol
    static let cvhBloodLipids = ScoreDefinition(default: 0, scoringBands: [
        .inRange(..<55, score: 1, explainer: "< 55"),
        .inRange(55..<70, score: 0.9, explainer: "55 – 69"),
        .inRange(70..<100, score: 0.8, explainer: "70 – 99"),
        .inRange(100..<130, score: 0.6, explainer: "100 – 129"),
        .inRange(130..<160, score: 0.4, explainer: "130 – 159"),
        .inRange(160..<190, score: 0.2, explainer: "160 – 189"),
        .inRange(190..., score: 0, explainer: "190+")
    ])
    
    static let cvhBloodGlucose = ScoreDefinition(default: 0, scoringBands: [
        .inRange(..<85, score: 1, explainer: "< 85"),
        .inRange(85..<100, score: 0.9, explainer: "85 – 99"),
        .inRange(100..<110, score: 0.75, explainer: "100 – 109"),
        .inRange(110..<126, score: 0.5, explainer: "110 – 125"),
        .inRange(126..<140, score: 0.25, explainer: "126 – 139"),
        .inRange(140..., score: 0, explainer: "140+")
    ])
    
    static let cvhBloodPressure = ScoreDefinition(
        default: 0,
        // ideally we'd simply put the explanation directly into the ScoreDefinition, and have it work in a way that
        // the UI gets created based on that; but for the time being we simply have this ScoreDefinition hardcoded.
        explainer: .init(footerText: nil, bands: [
            .init(leadingText: "<120 / <80", background: .color(Gradient.redToGreen.color(at: 1))),
            .init(leadingText: "120–129 / 80–89", background: .color(Gradient.redToGreen.color(at: 0.8))),
            .init(leadingText: "130–139 / 90–99", background: .color(Gradient.redToGreen.color(at: 0.5))),
            .init(leadingText: "140+ / 90+", background: .color(Gradient.redToGreen.color(at: 0.1)))
        ])
    ) { (measurement: BloodPressureMeasurement) in
        let systolicScore: Double = switch measurement.systolic as Int {
        case ..<121: 0.75
        case 121...129: 0.65
        case 130...139: 0.5
        case 140...159: 0.25
        case 160...: 0
        default: 0 // unreachable
        }
        let diastolicScore: Double = switch measurement.diastolic as Int {
        case ..<81: 0.25
        case 81...89: 0.15
        case 90...99: 0.05
        case 100...: 0
        default: 0 // unreachable
        }
        return systolicScore + diastolicScore
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

extension HKQuantitySample: CVHScore.ComponentSampleProtocol {}
extension HKCorrelation: CVHScore.ComponentSampleProtocol {}

extension SleepSession: CVHScore.ComponentSampleProtocol {}

extension HKStatistics: CVHScore.ComponentSampleProtocol {
    var timeRange: Range<Date> {
        startDate..<endDate
    }
}


extension HealthKit.SourceFilter {
    static let appleHealthSystem = Self.bundleId(beginsWith: "com.apple.health")
}


extension CVHScore {
    static var sleepDataSourceFilter: HealthKit.SourceFilter {
        LaunchOptions.launchOptions[Self.considerAllSleepDataLaunchOption] ? .any : .appleHealthSystem
    }
    
    private static let considerAllSleepDataLaunchOption = LaunchOption<Bool>("--dashboardConsiderAllSleepData", default: false)
}
