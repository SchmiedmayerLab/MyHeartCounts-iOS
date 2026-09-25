//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Charts
import Foundation
import GroveFoundation
import GroveHealthKit
import MyHeartCountsShared
import SwiftUI


struct LargeSleepAnalysisTile: View {
    enum Accessory {
        case none
        case timeRangeSelector(Binding<DetailedHealthStatsView.ChartTimeRange>)
        
        init(_ other: DefaultHealthDashboardTile.Accessory) {
            switch other {
            case .none:
                self = .none
            case .timeRangeSelector(let binding):
                self = .timeRangeSelector(binding)
            }
        }
    }
    
    @Environment(\.calendar)
    private var cal
    
    private let accessory: Accessory
    private let queryTimeRange: HealthKitQueryTimeRange
    @StatsDocumentsQuery<SleepSessionStatsSample> private var sleepSessions: [SleepSessionStatsSample]
    @State private var xSelection: Date?
    
    private var timeRange: Range<Date> {
        queryTimeRange.range
    }
    
    /// the total time asleep (in seconds) per day, with the sessions attributed to the day they ended on
    private var timeAsleepByDay: [Date: TimeInterval] {
        sleepSessions.reduce(into: [:]) { acc, session in
            acc[cal.makeNoon(session.timeRange.upperBound), default: 0] += session.hoursAsleep * TimeConstants.hour
        }
    }
    
    var body: some View {
        HealthDashboardTile(title: SampleType.sleepAnalysis.mhcDisplayTitle) {
            switch accessory {
            case .none:
                EmptyView()
            case .timeRangeSelector(let binding):
                ChartTimeRangePicker(timeRange: binding)
            }
        } content: {
            cellContent
        }
    }
    
    @ViewBuilder private var cellContent: some View {
        Chart {
            chartContent
        }
        .chartOverlay { _ in
            if sleepSessions.isEmpty {
                Text("No Data")
            }
        }
        .chartXScale(domain: [
            cal.startOfDay(for: timeRange.lowerBound),
            timeRange.upperBound
        ])
        .configureChartXAxis(for: timeRange)
        .chartXSelection(value: $xSelection)
    }
    
    @ChartContentBuilder private var chartContent: some ChartContent {
        ForEach(sleepSessions, id: \.self) { session in
            BarMark(
                x: .value("Date", cal.makeNoon(session.timeRange.upperBound)),
                y: .value("Time Asleep", session.hoursAsleep),
                width: .automatic
            )
            .foregroundStyle(Color.blue)
        }
        if let xSelection,
           case let timeAsleepInDay = timeAsleepByDay[cal.makeNoon(xSelection)] ?? 0 {
            ChartHighlightRuleMark(
                x: .value("Selected", xSelection, unit: .day, calendar: cal),
                config: .init(
                    primary: formatDuration(timeAsleepInDay),
                    secondary: Text(xSelection.formatted(.dateTime.calendar(cal).omittingTime()))
                )
            )
        }
    }
    
    init(timeRange: HealthKitQueryTimeRange, accessory: Accessory) {
        self.accessory = accessory
        self.queryTimeRange = timeRange
        self._sleepSessions = .init(sleepSessionsIn: timeRange)
    }
    
    private func formatDuration(_ duration: TimeInterval) -> Text {
        let hours = Int(duration / TimeConstants.hour)
        let minutes = Int(duration.truncatingRemainder(dividingBy: TimeConstants.hour) / TimeConstants.minute)
        return Text("\(hours) hr \(minutes) min")
    }
}


extension Range where Bound: Strideable, Bound.Stride: FloatingPoint {
    var middle: Bound {
        guard !isEmpty else {
            return lowerBound
        }
        let distance: Bound.Stride = lowerBound.distance(to: upperBound)
        let halfDistance: Bound.Stride = distance / 2
        return lowerBound.advanced(by: halfDistance)
    }
}
