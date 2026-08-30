//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//


import Foundation
import GroveFoundation


extension Date {
    func shortDescription(
        locale: Locale = .current,
        calendar cal: Calendar = .current,
        timeZone: TimeZone = .current,
        relativeTo now: Date = .now
    ) -> String {
        if cal.isDate(self, inSameDayAs: now) {
            self.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: cal, timeZone: timeZone))
        } else if cal.isDate(self, inSameDayAs: cal.startOfPrevDay(for: now)) {
            String(localized: "Yesterday")
        } else {
            self.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, locale: locale, calendar: cal, timeZone: timeZone))
        }
    }
}
