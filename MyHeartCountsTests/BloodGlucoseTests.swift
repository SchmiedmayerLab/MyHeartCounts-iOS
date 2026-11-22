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
@testable import MyHeartCounts
import Testing


@Suite
struct BloodGlucoseTests {
    @Test
    func hbA1cScaleConversion() {
        // HKUnit would turn 6.5 % into 65 mmol/mol.
        #expect(abs(HbA1cScale.millimolesPerMole(fromPercent: 6.5) - 47.5) < 0.1)
        #expect(abs(HbA1cScale.millimolesPerMole(fromPercent: 5.7) - 38.8) < 0.1)
        #expect(abs(HbA1cScale.percent(fromMillimolesPerMole: 48) - 6.54) < 0.01)
        for percent in stride(from: 4.0, through: 14, by: 0.5) {
            #expect(abs(HbA1cScale.percent(fromMillimolesPerMole: HbA1cScale.millimolesPerMole(fromPercent: percent)) - percent) < 1e-9)
        }
    }

    @Test
    func hbA1cSampleConversion() {
        let sampleType = MHCQuantitySampleType.custom(.hbA1c)
        #expect(abs(sampleType.convert(6.5, from: .percent(), to: .hbA1cMillimolesPerMole) - 47.5) < 0.1)
        let sample = QuantitySample(id: UUID(), sampleType: sampleType, unit: .hbA1cMillimolesPerMole, value: 48, date: .now)
        #expect(abs(sample.value(as: .percent()) - 6.54) < 0.01)
        #expect(abs(sample.value(as: .hbA1cMillimolesPerMole) - 48) < 1e-9)
    }

    @Test
    func bloodGlucoseUnitConversion() {
        let sampleType = MHCQuantitySampleType.healthKit(.bloodGlucose)
        #expect(abs(sampleType.convert(100, from: .milligramsPerDeciliter, to: .bloodGlucoseMillimolesPerLiter) - 5.55) < 0.01)
        #expect(HKUnit.bloodGlucoseMillimolesPerLiter.mhcDisplayString == "mmol/L")
    }

    @Test
    func scoringBands() throws {
        // the bands are matched in the display unit; these assume a test environment that doesn't use the UK measurement system.
        try #require(Locale.current.measurementSystem != .uk)
        let glucose = ScoreDefinition.cvhBloodGlucose
        #expect(glucose(84.0) == 1)
        #expect(glucose(85.0) == 0.9)
        #expect(glucose(125.0) == 0.5)
        #expect(glucose(140.0) == 0)
        let hbA1c = ScoreDefinition.cvhHbA1c
        #expect(hbA1c(5.4) == 1)
        #expect(hbA1c(5.5) == 0.9)
        #expect(hbA1c(5.6) == 0.9)
        #expect(hbA1c(5.7) == 0.75)
        #expect(hbA1c(5.9) == 0.75)
        #expect(hbA1c(6.0) == 0.5)
        #expect(hbA1c(6.4) == 0.5)
        #expect(hbA1c(6.5) == 0.25)
        #expect(hbA1c(6.9) == 0.25)
        #expect(hbA1c(7.0) == 0)
        #expect(hbA1c(10.0) == 0)
    }

    @Test
    func scoreSource() throws {
        typealias Source = CVHScore.BloodGlucoseScoreSource
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let hbA1cDate = try #require(calendar.date(from: DateComponents(year: 2024, month: 3, day: 1)))
        let threeYearsEarlier = try #require(calendar.date(byAdding: .year, value: -3, to: hbA1cDate))
        let oneYearLater = try #require(calendar.date(byAdding: .year, value: 1, to: hbA1cDate))
        let twoYearsLater = try #require(calendar.date(byAdding: .year, value: 2, to: hbA1cDate))
        let twoYearsAndADayLater = try #require(calendar.date(byAdding: .day, value: 1, to: twoYearsLater))
        func source(_ hbA1cDate: Date?, _ fastingReadingDate: Date?) -> Source {
            Source(hbA1cDate: hbA1cDate, fastingReadingDate: fastingReadingDate, calendar: calendar)
        }
        // without an HbA1c value, the fasting reading scores (or there's no score)
        #expect(source(nil, nil) == .fastingReading)
        #expect(source(nil, hbA1cDate) == .fastingReading)
        // an HbA1c value scores, however old, unless the fasting reading is more than 2 years newer
        #expect(source(hbA1cDate, nil) == .hbA1c)
        #expect(source(hbA1cDate, threeYearsEarlier) == .hbA1c)
        #expect(source(hbA1cDate, oneYearLater) == .hbA1c)
        #expect(source(hbA1cDate, twoYearsLater) == .hbA1c)
        #expect(source(hbA1cDate, twoYearsAndADayLater) == .fastingReading)
    }

    @Test
    func individualReadingsAndHourlyAggregates() throws {
        let monthStart = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 1)))
        func sample(_ value: Double, minutes: Double, metadata: [String: Any] = [:]) -> HKQuantitySample {
            let date = monthStart.addingTimeInterval(minutes * 60)
            return HKQuantitySample(
                type: HKQuantityType(.bloodGlucose),
                quantity: HKQuantity(unit: .milligramsPerDeciliter, doubleValue: value),
                start: date,
                end: date,
                metadata: metadata
            )
        }
        // a few readings a day: all stored individually, with their meal time
        let sparse = [
            sample(90, minutes: 60, metadata: [HKMetadataKeyBloodGlucoseMealTime: HKBloodGlucoseMealTime.preprandial.rawValue]),
            sample(150, minutes: 120, metadata: [HKMetadataKeyBloodGlucoseMealTime: HKBloodGlucoseMealTime.postprandial.rawValue]),
            sample(95, minutes: 600)
        ]
        let sparseEntries = HealthKitStatsCalculator.bloodGlucoseEntries(for: sparse, monthStart: monthStart) { _ in "meter" }
        #expect(sparseEntries.readings.map(\.value) == [90, 150, 95])
        #expect(sparseEntries.readings.map(\.mealTime) == [.beforeMeal, .afterMeal, nil])
        #expect(sparseEntries.hourly.isEmpty)
        // a continuous glucose monitor (a reading every 5 minutes): hourly aggregates, except for the reading entered by hand
        let continuous = (0..<48).map { sample(100 + Double($0 % 12), minutes: Double($0) * 5) }
            + [sample(120, minutes: 30, metadata: [HKMetadataKeyWasUserEntered: true])]
        let continuousEntries = HealthKitStatsCalculator.bloodGlucoseEntries(for: continuous, monthStart: monthStart) { _ in "cgm" }
        #expect(continuousEntries.readings.map(\.value) == [120])
        #expect(continuousEntries.readings.first?.isUserEntered == true)
        #expect(continuousEntries.hourly.map(\.start) == (0..<4).map { monthStart.addingTimeInterval(Double($0) * 3600) })
    }
}
