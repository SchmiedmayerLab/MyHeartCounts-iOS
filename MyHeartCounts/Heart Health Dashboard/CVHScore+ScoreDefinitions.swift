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
import MyHeartCountsShared
import SwiftUI


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
    
    /// LDL Cholesterol, in mg/dL
    static let cvhBloodLipids = ScoreDefinition(default: 0, scoringBands: [
        .inRange(..<55, score: 1, explainer: "< 55"),
        .inRange(55..<70, score: 0.9, explainer: "55 – 69"),
        .inRange(70..<100, score: 0.8, explainer: "70 – 99"),
        .inRange(100..<130, score: 0.6, explainer: "100 – 129"),
        .inRange(130..<160, score: 0.4, explainer: "130 – 159"),
        .inRange(160..<190, score: 0.2, explainer: "160 – 189"),
        .inRange(190..., score: 0, explainer: "190+")
    ])
    
    /// Fasting blood glucose readings, matched in the participant's blood glucose display unit.
    ///
    /// The study team's bands, specified in mg/dL: < 85 → 1, 85–99 → 0.9, 100–109 → 0.75, 110–125 → 0.5, 126–139 → 0.25,
    /// 140+ → 0.
    static let cvhBloodGlucose = bands(
        upperBounds: [85, 100, 110, 126, 140],
        scores: [1, 0.9, 0.75, 0.5, 0.25, 0],
        specifiedIn: .milligramsPerDeciliter,
        sampleType: .healthKit(.bloodGlucose)
    )
    
    /// HbA1c, matched in the participant's HbA1c display unit.
    ///
    /// The study team's bands, specified in %: < 5.5 → 1, 5.5–5.6 → 0.9, 5.7–5.9 → 0.75, 6.0–6.4 → 0.5, 6.5–6.9 → 0.25,
    /// 7.0+ → 0.
    static let cvhHbA1c = bands(
        upperBounds: [5.5, 5.7, 6, 6.5, 7],
        scores: [1, 0.9, 0.75, 0.5, 0.25, 0],
        specifiedIn: .percent(),
        sampleType: .custom(.hbA1c)
    )
    
    
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


extension ScoreDefinition {
    /// Creates scoring bands that match values in the sample type's display unit, from band boundaries specified in another unit.
    ///
    /// The converted boundaries are rounded to the precision values get entered with in the display unit,
    /// so that the bands we show and the bands a value gets matched against agree.
    ///
    /// - parameter upperBounds: The exclusive upper bounds of all bands but the last one, in ascending order.
    /// - parameter scores: The bands' scores; one more than `upperBounds`.
    private static func bands(
        upperBounds: [Double],
        scores: [Double],
        specifiedIn boundsUnit: HKUnit,
        sampleType: MHCQuantitySampleType
    ) -> ScoreDefinition {
        precondition(scores.count == upperBounds.count + 1)
        let unit = sampleType.displayUnit
        let fractionDigits = sampleType.prefersNonDecimalValues(in: unit) ? 0 : 1
        let step = pow(10, -Double(fractionDigits))
        let bounds = upperBounds.map { bound in
            (sampleType.convert(bound, from: boundsUnit, to: unit) / step).rounded() * step
        }
        func format(_ value: Double) -> String {
            value.formatted(.number.precision(.fractionLength(fractionDigits)))
        }
        let scoringBands: [ScoringBand] = scores.indices.map { idx in
            let score = scores[idx]
            switch idx {
            case 0:
                return .inRange(..<bounds[0], score: score, explainer: "< \(format(bounds[0]))")
            case bounds.count:
                return .inRange(bounds[idx - 1]..., score: score, explainer: "\(format(bounds[idx - 1]))+")
            default:
                return .inRange(
                    bounds[idx - 1]..<bounds[idx],
                    score: score,
                    explainer: "\(format(bounds[idx - 1])) – \(format(bounds[idx] - step))"
                )
            }
        }
        return ScoreDefinition(default: 0, scoringBands: scoringBands)
    }
}
