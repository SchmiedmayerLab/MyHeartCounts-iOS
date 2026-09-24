//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

// periphery:ignore:all

import Foundation
import GroveFoundation
import GroveLocalization
@testable import MyHeartCounts
import Testing


@Suite
final class DateRangeTests {
    private struct DateInput {
        enum Day {
            case absolute(year: Int, month: Int, day: Int)
            case relative(offsetFromToday: Int)
            static let yesterday: Self = .relative(offsetFromToday: -1)
            static let today: Self = .relative(offsetFromToday: 0)
            static let tomorrow: Self = .relative(offsetFromToday: 1)
        }
        enum Time {
            case absolute(hour: Int, minute: Int, second: Int = 0)
            static let midnight: Self = .absolute(hour: 0, minute: 0, second: 0)
        }
        
        let day: Day
        let time: Time
    }
    
    
    private struct LocalizationConfig {
        static let usWestCoast = Self(locale: .enUS, timeZone: .losAngeles)
        static let germanyEnglish = Self(locale: .enDE, timeZone: .berlin)
        
        let locale: Locale
        let timeZone: TimeZone
        let calendar: Calendar
        
        init(locale: Locale, timeZone: TimeZone) {
            self.locale = locale
            self.timeZone = timeZone
            var cal = locale.calendar
            cal.timeZone = timeZone
            self.calendar = cal
        }
    }
    
    private var localizationConfig: LocalizationConfig = .usWestCoast
    
    private var locale: Locale { localizationConfig.locale }
    private var timeZone: TimeZone { localizationConfig.timeZone }
    private var cal: Calendar { locale.calendar }
    
    private func usingLocalization(_ config: LocalizationConfig, _ test: () throws -> Void) rethrows {
        let prevConfig = self.localizationConfig
        defer {
            self.localizationConfig = prevConfig
        }
        self.localizationConfig = config
        try test()
    }
    
    
    private func date(from input: DateInput, now: Date, sourceLocation: SourceLocation = #_sourceLocation) throws -> Date {
        var date = switch input.day {
        case let .absolute(year, month, day):
            try #require(cal.date(from: .init(calendar: cal, year: year, month: month, day: day)), sourceLocation: sourceLocation)
        case .relative(let offsetFromToday):
            try #require(cal.date(byAdding: .day, value: offsetFromToday, to: cal.startOfDay(for: now)), sourceLocation: sourceLocation)
        }
        date = switch input.time {
        case let .absolute(hour, minute, second):
            try #require(cal.date(bySettingHour: hour, minute: minute, second: second, of: date), sourceLocation: sourceLocation)
        }
        return date
    }
    
    private func check(
        start: DateInput,
        end: DateInput,
        now: Date = .now,
        expected: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let start = try date(from: start, now: now)
        let end = try date(from: end, now: now)
        let range = start..<end
        let actual = range.displayText(using: locale, calendar: cal, now: now)
        #expect(actual == expected, sourceLocation: sourceLocation)
    }
    
    
    @Test
    func dateRangeDisplayText() throws {
        // NOTE: the time strings here have a special unicode space character before the AM or PM component.
        // not sure why but foundation uses that instead of a normal space: ' '
        try check(
            start: .init(day: .today, time: .midnight),
            end: .init(day: .tomorrow, time: .midnight),
            expected: "Today"
        )
        try check(
            start: .init(day: .yesterday, time: .midnight),
            end: .init(day: .today, time: .midnight),
            expected: "Yesterday"
        )
        try check(
            start: .init(day: .absolute(year: 2025, month: 3, day: 7), time: .midnight),
            end: .init(day: .absolute(year: 2025, month: 3, day: 19), time: .midnight),
            expected: "Mar 7, 2025 – Mar 18, 2025"
        )
        try check(
            start: .init(day: .yesterday, time: .absolute(hour: 14, minute: 15)),
            end: .init(day: .today, time: .midnight),
            expected: "Yesterday 2:15 PM – 11:59 PM"
        )
    }
    
    @Test
    func fmtMultiDayDateRanges() throws {
        try check(
            start: .init(day: .absolute(year: 2025, month: 9, day: 5), time: .absolute(hour: 14, minute: 15)),
            end: .init(day: .absolute(year: 2025, month: 9, day: 9), time: .absolute(hour: 17, minute: 49)),
            expected: "Sep 5, 2025 at 2:15 PM – Sep 9, 2025 at 5:49 PM"
        )
        try check(
            start: .init(day: .absolute(year: 2025, month: 9, day: 5), time: .midnight),
            end: .init(day: .absolute(year: 2025, month: 9, day: 9), time: .absolute(hour: 17, minute: 49)),
            expected: "Sep 5, 2025 at 12:00 AM – Sep 9, 2025 at 5:49 PM"
        )
        try check(
            start: .init(day: .absolute(year: 2025, month: 9, day: 5), time: .absolute(hour: 14, minute: 15)),
            end: .init(day: .absolute(year: 2025, month: 9, day: 9), time: .midnight),
            expected: "Sep 5, 2025 at 2:15 PM – Sep 8, 2025 at 11:59 PM"
        )
        try check(
            start: .init(day: .absolute(year: 2025, month: 9, day: 5), time: .midnight),
            end: .init(day: .absolute(year: 2025, month: 9, day: 9), time: .midnight),
            expected: "Sep 5, 2025 – Sep 8, 2025"
        )
    }
    
    @Test
    func fmtDateRangeInToday() throws {
        try check(
            start: .init(day: .today, time: .absolute(hour: 9, minute: 15)),
            end: .init(day: .today, time: .absolute(hour: 14, minute: 0, second: 0)),
            expected: "9:15 AM – 2:00 PM"
        )
        try check(
            start: .init(day: .yesterday, time: .absolute(hour: 21, minute: 47, second: 0)),
            end: .init(day: .today, time: .absolute(hour: 7, minute: 21, second: 0)),
            expected: "Yesterday 9:47 PM – Today 7:21 AM"
        )
    }
}
