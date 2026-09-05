//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
@testable import MyHeartCounts
import Testing


@Suite
struct HealthKitStatsCalculatorTests {
    private typealias Coverage = HealthKitStatsCalculator.Coverage
    
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")! // swiftlint:disable:this force_unwrapping
        return calendar
    }()
    
    /// Midnight at the start of the day, in the test calendar's time zone.
    private func date(_ year: Int, _ month: Int, _ day: Int) throws -> Date {
        try #require(calendar.date(from: DateComponents(year: year, month: month, day: day)))
    }
    
    /// A fresh enrollee's coverage reaches back the requested number of months before the current one.
    @Test
    func coverageReachesBackBeforeTheEnrollment() throws {
        let months = HealthKitStatsCalculator.months(
            since: try date(2026, 9, 2),
            coverage: Coverage(precedingMonths: 3),
            now: try date(2026, 9, 4),
            calendar: calendar
        )
        #expect(months.map(\.documentId) == ["2026-06", "2026-07", "2026-08", "2026-09"])
    }
    
    /// `.sinceEnrollment` covers the enrollment month onwards, and nothing before it.
    @Test
    func sinceEnrollmentCoversOnlyTheEnrollmentMonthOnwards() throws {
        let months = HealthKitStatsCalculator.months(
            since: try date(2026, 9, 2),
            coverage: .sinceEnrollment,
            now: try date(2026, 9, 4),
            calendar: calendar
        )
        #expect(months.map(\.documentId) == ["2026-09"])
    }
    
    /// For a participant who enrolled long ago, the coverage floor doesn't shorten the months since the enrollment.
    @Test
    func coverageDoesNotShortenTheMonthsSinceTheEnrollment() throws {
        let months = HealthKitStatsCalculator.months(
            since: try date(2025, 1, 15),
            coverage: Coverage(precedingMonths: 3),
            now: try date(2026, 9, 4),
            calendar: calendar
        )
        #expect(months.count == 21)
        #expect(months.first?.documentId == "2025-01")
        #expect(months.last?.documentId == "2026-09")
    }
    
    /// A month's range spans exactly that month, in the calendar's time zone.
    @Test
    func monthContainingADate() throws {
        let month = try #require(HealthKitStatsCalculator.month(containing: try date(2019, 4, 17), calendar: calendar))
        #expect(month.documentId == "2019-04")
        let expectedRange = try date(2019, 4, 1)..<date(2019, 5, 1)
        #expect(month.range == expectedRange)
    }
}
