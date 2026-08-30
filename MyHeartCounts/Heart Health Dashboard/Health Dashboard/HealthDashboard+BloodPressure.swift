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
import GroveHealthKitUI
import SwiftUI


struct SmallBloodPressureTile: View {
    @HealthKitQuery(.bloodPressure, timeRange: .last(months: 6))
    private var samples
    
    var body: some View {
        HealthDashboardTile(title: $samples.sampleType.mhcDisplayTitle) {
            if let sample = samples.last,
               let systolic = sample.firstSample(ofType: .bloodPressureSystolic),
               let diastolic = sample.firstSample(ofType: .bloodPressureDiastolic) {
                let unit = SampleType.bloodPressureSystolic.displayUnit
                HealthDashboardQuantityLabel(input: .init(
                    value: nil,
                    valueString: "\(Int(systolic.quantity.doubleValue(for: unit)))/\(Int(diastolic.quantity.doubleValue(for: unit)))",
                    unit: unit,
                    timeRange: sample.timeRange
                ))
            } else {
                Text("No Data")
                    .foregroundStyle(.secondary)
            }
        }
    }
}


struct LargeBloodPressureTile: View {
    private let accessory: LargeSleepAnalysisTile.Accessory
    
    @Environment(\.calendar)
    private var cal
    
    @HealthKitQuery<HKCorrelation> private var samples: Slice<OrderedArray<HKCorrelation>>
    
    var body: some View {
        HealthDashboardTile(title: $samples.sampleType.mhcDisplayTitle) {
            switch accessory {
            case .none:
                EmptyView()
            case .timeRangeSelector(let binding):
                ChartTimeRangePicker(timeRange: binding)
            }
        } content: {
            Chart(samples) { sample in
                let styleSystolic: some ShapeStyle = Color.red
                let styleDiastolic: some ShapeStyle = Color.blue
                if let systolic = sample.firstSample(ofType: .bloodPressureSystolic),
                   let diastolic = sample.firstSample(ofType: .bloodPressureDiastolic) {
                    let xVal: PlottableValue = .value("Date", sample.endDate)
                    let yValSystolic: PlottableValue = .value("Value", systolic.quantity.doubleValue(for: .millimeterOfMercury()))
                    let yValDiastolic: PlottableValue = .value("Value", diastolic.quantity.doubleValue(for: .millimeterOfMercury()))
                    PointMark(x: xVal, y: yValSystolic)
                        .foregroundStyle(styleSystolic)
                    PointMark(x: xVal, y: yValDiastolic)
                        .foregroundStyle(styleDiastolic)
                    LineMark(x: xVal, y: yValSystolic, series: .value("Series", "Systolic"))
                        .foregroundStyle(styleSystolic)
                    LineMark(x: xVal, y: yValDiastolic, series: .value("Series", "Diastolic"))
                        .foregroundStyle(styleDiastolic)
                }
            }
            .chartOverlay { _ in
                if samples.isEmpty {
                    Text("No Data")
                }
            }
            .chartXScale(domain: [
                cal.startOfDay(for: $samples.timeRange.range.lowerBound),
                cal.startOfNextDay(for: $samples.timeRange.range.upperBound).addingTimeInterval(-1)
            ])
            .configureChartXAxis(for: $samples.timeRange.range)
        }
    }
    
    init(
        timeRange: HealthKitQueryTimeRange,
        accessory: LargeSleepAnalysisTile.Accessory
    ) {
        self.accessory = accessory
        self._samples = .init(.bloodPressure, timeRange: timeRange)
    }
}
