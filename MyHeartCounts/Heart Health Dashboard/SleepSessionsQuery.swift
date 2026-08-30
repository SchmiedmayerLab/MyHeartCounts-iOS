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
import GroveHealthKitUI
import MyHeartCountsShared
import SwiftUI


/// Fetches Sleep Analysis samples from HealthKit and processes them into `SleepSession`s.
///
/// The advantage of this property wrapper, compared to fetching and processing the samples directly, is that it correctly handles the edge case of a sleep session falling into multiple days.
/// (Manually fetching and processing the samples would potentially result in a partial sleep session, depending on the chosen query time range.)
@MainActor
@propertyWrapper
struct SleepSessionsQuery: DynamicProperty {
    struct ProcessingResult {
        let sessions: [SleepSession]
        /// key: noon
        /// value: total "asleep" duration of all sleep sessions that have their end in the `key` day.
        let timeAsleepByDay: [Date: TimeInterval]
    }
    
    enum ProcessingState {
        case processing
        case done(ProcessingResult)
        case failed(any Error)
    }
    
    @Environment(\.calendar)
    private var cal
    
    @HealthKitQuery<HKCategorySample> private var samples: Slice<OrderedArray<HKCategorySample>>
    
    /// The actual time range the query returns sleep sessions for.
    let timeRange: Range<Date>
    
    @State private var sleepDataProcessor = SleepDataProcessor()
    @State private(set) var processingState: ProcessingState = .processing
    
    var wrappedValue: [SleepSession] {
        switch processingState {
        case .done(let result):
            result.sessions
        case .processing, .failed:
            []
        }
    }
    
    var projectedValue: Self {
        self
    }
    
    init(timeRange: HealthKitQueryTimeRange, source: HealthKit.SourceFilter = .any) {
        self.timeRange = timeRange.range
        self._samples = .init(.sleepAnalysis, timeRange: Self.adjustTimeRange(timeRange), source: source)
    }
    
    nonisolated func update() {
        Task { @MainActor in
            updateSleepSessions()
        }
    }
    
    @MainActor
    private func updateSleepSessions() {
        let samples = withObservationTracking {
            Array(self.samples)
        } onChange: {
            Task { @MainActor in
                updateSleepSessions()
            }
        }
        Task { @concurrent in
            let state: ProcessingState
            do {
                state = .done(try await self.sleepDataProcessor.process(samples, timeRange: timeRange, using: cal))
            } catch {
                state = .failed(error)
            }
            await MainActor.run {
                self.processingState = state
            }
        }
    }
}


extension SleepSessionsQuery {
    private static func adjustTimeRange(_ timeRange: HealthKitQueryTimeRange) -> HealthKitQueryTimeRange {
        let range = timeRange.range
        // no need to perform expensive Calendar operations here; we simply extend the range by a day in each direction.
        return .init(range.lowerBound.addingTimeInterval(-TimeConstants.day)..<range.upperBound.addingTimeInterval(TimeConstants.day))
    }
}


extension SleepSessionsQuery {
    // We use an actor here to simplify things, bc we don't want multiple calls with the same input to perform the sessions calc multiple times.
    private actor SleepDataProcessor {
        private var lastSeenSleepSamples: [HKCategorySample] = []
        private var lastResult: ProcessingResult?
        
        func process(
            _ sleepSamples: some Collection<HKCategorySample>,
            timeRange: Range<Date>,
            using cal: Calendar
        ) throws -> ProcessingResult {
            if let lastResult, sleepSamples.elementsEqual(lastSeenSleepSamples) {
                return lastResult
            }
            let sleepSamples = Array(sleepSamples)
            self.lastSeenSleepSamples = sleepSamples
            let sessions = try sleepSamples.splitIntoSleepSessions().filter { session in
                timeRange.contains(session.timeRange.middle)
            }
            let result = ProcessingResult(
                sessions: sessions,
                timeAsleepByDay: sessions.reduce(into: [:], { acc, session in
                    acc[cal.makeNoon(session.endDate), default: 0] += session.totalTimeSpentAsleep
                })
            )
            self.lastResult = result
            return result
        }
    }
}
