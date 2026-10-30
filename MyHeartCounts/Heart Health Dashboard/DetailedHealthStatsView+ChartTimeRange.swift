//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFoundation
import GroveHealthKit


extension DetailedHealthStatsView {
    /// A user-selectable time range for what should be displayed in the chart on a metric's page.
    ///
    /// - Note: We need to use this, instead of using `HealthKitQueryTimeRange` directly, since that stores absolute time ranges, but we're interested in relative ones.
    enum ChartTimeRange: Hashable {
        /// The time range representing the entirety the most last `N` days, starting at the end of today.
        case lastNumDays(Int)
        /// The time range representing the entirety the most last `N` weeks, starting at the end of today.
        case lastNumWeeks(Int)
        /// The time range representing the entirety the most last `N` months, starting at the end of today.
        case lastNumMonths(Int)
        
        static let selectableOptions: [Self] = [
            .lastNumDays(7),
            .lastNumDays(14),
            .lastNumMonths(1),
            .lastNumMonths(3),
            .lastNumMonths(6),
            .lastNumMonths(12)
        ]
        
        var displayTitle: LocalizedStringResource {
            switch self {
            case .lastNumDays(let count):
                "Last \(count) days"
            case .lastNumWeeks(let count):
                "Last \(count) weeks"
            case .lastNumMonths(let count):
                "Last \(count) months"
            }
        }
    }
}


extension HealthKitQueryTimeRange {
    init(_ other: DetailedHealthStatsView.ChartTimeRange) {
        switch other {
        case .lastNumDays(let count):
            self = .last(days: count)
        case .lastNumWeeks(let count):
            self = .last(days: count * 7)
        case .lastNumMonths(let count):
            let cal = Calendar.current
            let end = cal.startOfNextDay(for: .now)
            guard let start = cal.date(byAdding: .month, value: -count, to: end) else {
                fatalError("Unable to compute start date")
            }
            self = .init(start..<end)
        }
    }
}
