//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import SpeziFoundation
import SpeziScheduler
import SpeziStudy
import SwiftUI


/// Fetches all events we want to prompt the user to complete today.
@MainActor
@propertyWrapper
struct MHCTodaysEventsQuery: DynamicProperty {
    /// The query's primary time range.
    ///
    /// Note that this is **not** the full time range being queried for, but rather the time range for which we want all events.
    private let primaryTimeRange: Range<Date>
    @EventQuery private var impl: [Event]
    
    var wrappedValue: [Event] {
        impl.filter { event in
            if primaryTimeRange.contains(event.occurrence.start) {
                // if the event is in the primary time range, it always gets included
                return true
            } else if event.occurrence.schedule.recurrence == nil {
                // if the schedule is a one-off thing, we also always include it.
                // this is intended to catch initial one-off study components that haven't been completed.
                // exception here is if the event is already completed, and the completion is outside of the primaryTimeRange.
                // ie, we always show the one-off events if they are still open, and once they are completed we continue showing them until the end of the day.
                if let completionDate = event.outcome?.completionDate {
                    // show the event if it was completed recently (w/in the primaryTimeRange)
                    return primaryTimeRange.contains(completionDate)
                } else { // !event.isCompleted
                    // always show yet-to-be-completed events
                    return true
                }
            } else {
                return false
            }
        }
    }
    
    init(_ timeRange: Range<Date>, dateOfEnrollment: Date) {
        self.primaryTimeRange = timeRange
        _impl = .init(in: min(timeRange.lowerBound, Calendar.current.startOfDay(for: dateOfEnrollment))..<timeRange.upperBound)
    }
}
