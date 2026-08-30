//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveScheduler
import SwiftUI


/// Fetches past missed events.
@propertyWrapper
@MainActor
struct MissedEventQuery: DynamicProperty { // Maybe donate to GroveScheduler at some point?!
    @EventQuery private var pastEvents: [Event]
    @EventQuery private var upcomingEvents: [Event]
    
    var wrappedValue: [Event] {
        pastEvents.filter { event in
            guard !event.isCompleted else {
                // filtering out past event bc it already completed, i.e. very much not missed
                return false
            }
            guard let nextOccurrence = event.occurrence.schedule
                // NOTE: we still need to fetch for the entire range here, bc we want to filter out those events which have additional occurrences in the past range.
                .occurrences(in: event.occurrence.start.addingTimeInterval(1)..<$upcomingEvents.range.upperBound)
                .first(where: { _ in true }) else {
                // if the event has no next occurrence, we allow it to stay around
                // filtering out bc no next occurrence
                return false
            }
            guard $upcomingEvents.range.contains(nextOccurrence.start) else {
                // filtering out bc next occurrence (\(nextOccurrence.start)) not in uocoming range
                return false
            }
            guard let upcomingEvent = upcomingEvents.first(where: { $0.task.id == event.task.id && $0.occurrence == nextOccurrence }) else {
                // filtering out bc no matching upcomingEvent
                return false
            }
            guard !upcomingEvent.isCompleted else {
                // if the next upcoming event is already completed, we don't offer the previous one anymore.
                // filtering out bc upcoming occurrence is already completed
                return false
            }
            // we've determined that this Event is the most recent not-yet-completed occurence of a Task.
            // as a result, we include it in the list of missed events.
            return true
        }
    }
    
    /// - parameter timeRange: The (forward-looking) time range, for which we want to find the most-recent missed events.
    init(in timeRange: Range<Date>) {
        _pastEvents = .init(
            in: timeRange.lowerBound.addingTimeInterval(-timeRange.lowerBound.distance(to: timeRange.upperBound))..<timeRange.lowerBound
        )
        _upcomingEvents = .init(in: timeRange)
    }
}
