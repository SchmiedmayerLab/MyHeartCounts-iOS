//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveHealthKit
import GroveHealthKitUI
import HealthKit
@testable import MyHeartCounts
import SwiftUI
import Testing


@Suite
struct ScoreCalcTests {
    @Test
    func scoreCalcA() {
        let score = ScoreDefinition(default: 0, scoringBands: [
            .inRange(0..<5, score: 1),
            .inRange(5..<10, score: 2),
            .equal(to: 12, score: 12, explainerBand: .init(leadingText: "12", trailingText: "12", background: .color(.red)))
        ])
        #expect(score(0) == 1)
        #expect(score(-0) == 1)
        #expect(score(-1) == 0)
        #expect(score(4) == 1)
        #expect(score(5) == 2)
        #expect(score(9) == 2)
        #expect(score(10) == 0)
        #expect(score(12) == 12)
    }
    
    @Test
    func scoreCalcB() {
        let score = ScoreDefinition.cvhBloodPressure
        #expect(score(BloodPressureMeasurement(systolic: 110, diastolic: 75)) == 1)
    }
    
    /// The lipids score must use the unit its bands are defined in (mg/dL), regardless of the sample type's display unit.
    @Test
    @MainActor
    func bloodLipidsScoreIgnoresDisplayUnit() {
        let mgPerDL: HKUnit = .gramUnit(with: .milli) / .literUnit(with: .deci)
        let cholesterolMmolPerL: HKUnit = .moleUnit(with: .milli, molarMass: 386.65) / .liter()
        let sampleType = CustomQuantitySampleType(
            id: "MHCTestSampleTypeBloodLipidsMmolPerL",
            canonicalUnit: mgPerDL,
            displayTitle: "Blood Lipids",
            displayUnit: cholesterolMmolPerL,
            aggregationKind: .avg,
            preferredTintColor: .red
        )
        let sample = QuantitySample(id: UUID(), sampleType: .custom(sampleType), unit: mgPerDL, value: 120, date: .now)
        let result = CVHScore.bloodLipidsScore(for: sample)
        #expect(result.inputValue as? Double == 120)
        #expect(result.score == 0.6)
    }
}
