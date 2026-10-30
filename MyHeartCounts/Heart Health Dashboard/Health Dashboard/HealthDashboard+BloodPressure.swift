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
import SwiftUI


struct LargeBloodPressureTile: View {
    private let accessory: LargeSleepAnalysisTile.Accessory
    private let timeRange: HealthKitQueryTimeRange
    
    @Environment(\.calendar)
    private var cal
    
    @StatsDocumentsQuery<BloodPressureStatsSample> private var samples: [BloodPressureStatsSample]
    
    var body: some View {
        HealthDashboardTile(title: SampleType.bloodPressure.mhcDisplayTitle) {
            switch accessory {
            case .none:
                EmptyView()
            case .timeRangeSelector(let binding):
                ChartTimeRangePicker(timeRange: binding)
            }
        } content: {
            Chart(samples, id: \.self) { sample in
                let styleSystolic: some ShapeStyle = Color.red
                let styleDiastolic: some ShapeStyle = Color.blue
                let xVal: PlottableValue = .value("Date", sample.date)
                let yValSystolic: PlottableValue = .value("Value", sample.systolic)
                let yValDiastolic: PlottableValue = .value("Value", sample.diastolic)
                PointMark(x: xVal, y: yValSystolic)
                    .foregroundStyle(styleSystolic)
                PointMark(x: xVal, y: yValDiastolic)
                    .foregroundStyle(styleDiastolic)
                LineMark(x: xVal, y: yValSystolic, series: .value("Series", "Systolic"))
                    .foregroundStyle(styleSystolic)
                LineMark(x: xVal, y: yValDiastolic, series: .value("Series", "Diastolic"))
                    .foregroundStyle(styleDiastolic)
            }
            .chartOverlay { _ in
                if samples.isEmpty {
                    Text("No Data")
                }
            }
            .chartXScale(domain: [
                cal.startOfDay(for: timeRange.range.lowerBound),
                cal.startOfNextDay(for: timeRange.range.upperBound).addingTimeInterval(-1)
            ])
            .configureChartXAxis(for: timeRange.range)
        }
    }
    
    init(
        timeRange: HealthKitQueryTimeRange,
        accessory: LargeSleepAnalysisTile.Accessory
    ) {
        self.accessory = accessory
        self.timeRange = timeRange
        self._samples = .init(bloodPressureIn: timeRange)
    }
}
