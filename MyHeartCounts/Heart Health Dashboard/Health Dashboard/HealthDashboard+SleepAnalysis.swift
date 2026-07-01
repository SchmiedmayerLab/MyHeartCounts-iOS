//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Charts
import Foundation
import HealthKit
import MyHeartCountsShared
import SpeziFoundation
import SpeziHealthKit
import SpeziHealthKitUI
import SwiftUI


struct SmallSleepAnalysisTile: View {
    @SleepSessionsQuery(timeRange: .last(days: 4), source: CVHScore.sleepDataSourceFilter)
    private var sleepSessions
    
    var body: some View {
        HealthDashboardTile(title: SampleType.sleepAnalysis.mhcDisplayTitle) {
            EmptyView() // ?
        } content: {
            if let session = sleepSessions.last {
                let value = session.totalTimeSpentAsleep / 60 / 60
                HealthDashboardQuantityLabel(input: .init(
                    value: value,
                    valueString: String(format: "%.1f", value), // have "Xhrs Ymin" instead?
                    unit: .hour(),
                    timeRange: session.timeRange
                ))
            }
        }
    }
}


struct LargeSleepAnalysisTile: View {
    enum Accessory {
        case none
        case timeRangeSelector(Binding<DetailedHealthStatsView.ChartTimeRange>)
        
        init(_ other: DefaultHealthDashboardTile.Accessory) {
            switch other {
            case .none, .progress:
                self = .none
            case .timeRangeSelector(let binding):
                self = .timeRangeSelector(binding)
            }
        }
    }
    
    @Environment(\.calendar)
    private var cal
    
    private let accessory: Accessory
    @SleepSessionsQuery private var sleepSessions: [SleepSession]
    @State private var xSelection: Date?
    
    private var timeRange: Range<Date> {
        $sleepSessions.timeRange
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
            switch $sleepSessions.processingState {
            case .processing:
                ProgressView("Processing Sleep Data…")
            case .done:
                EmptyView()
            case .failed:
                Text("Failed to process Sleep Sessions")
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
        switch $sleepSessions.processingState {
        case .processing, .failed:
            EmptyChartContent()
        case .done(let data):
            if !data.sessions.isEmpty {
                chartContent(for: data)
            } else {
                // ???
            }
        }
    }
    
    init(timeRange: HealthKitQueryTimeRange, accessory: Accessory) {
        self.accessory = accessory
        self._sleepSessions = .init(timeRange: timeRange, source: CVHScore.sleepDataSourceFilter)
    }
    
    /// - precondition: `sleepSessions` may not be empty.
    @ChartContentBuilder
    private func chartContent(for sleepData: SleepSessionsQuery.ProcessingResult) -> some ChartContent {
        ForEach(sleepData.sessions, id: \.self) { session in
            BarMark(
                x: .value("Date", cal.makeNoon(session.endDate)),
                y: .value("Time Asleep", session.totalTimeSpentAsleep / TimeConstants.hour),
                width: .automatic
            )
            .foregroundStyle(Color.blue)
        }
        if let xSelection,
           case let timeAsleepInDay = sleepData.timeAsleepByDay[cal.makeNoon(xSelection)] ?? 0 {
            ChartHighlightRuleMark(
                x: .value("Selected", xSelection, unit: .day, calendar: cal),
                config: .init(
                    primary: formatDuration(timeAsleepInDay),
                    secondary: Text(xSelection.formatted(.dateTime.calendar(cal).omittingTime()))
                )
            )
        }
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
