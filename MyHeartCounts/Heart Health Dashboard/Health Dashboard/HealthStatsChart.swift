//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

// swiftlint:disable file_types_order

import Charts
import Foundation
import GroveFoundation
import GroveHealthKitUI
import GroveViews
import HealthKit
import MyHeartCountsShared
import SwiftUI


struct ChartDataSetDrawingConfig: Sendable {
    /// A chart type.
    enum ChartType: Sendable {
        /// The entry is drawn as a line chart, i.e. a line that moves from data point to data point
        case line(interpolationMethod: InterpolationMethod = .linear)
        /// bar chart
        case bar
        /// each data point is its own point in the chart, not connected to anything else
        case point(area: Double? = 10)
    }
    
    let chartType: ChartType
    let color: Color
    
    /// Creates a new drawing config for an entry in a health chart.
    init(chartType: ChartType, color: Color) {
        self.chartType = chartType
        self.color = color
    }
}


struct HealthStatsChartDataPoint: Hashable, Sendable {
    struct HighlightConfiguration {
        let primary: Text
        let secondary: Text?
        
        static func `default`(
            for dataPoint: HealthStatsChartDataPoint,
            in dataSet: some HealthStatsChartDataSetProtocol
        ) -> Self {
            Self(
                primary: { () -> Text in
                    let labelInput = HealthDashboardQuantityLabel.Input(
                        value: dataPoint.value,
                        sampleType: dataSet.sampleType,
                        timeRange: dataPoint.timeRange
                    )
                    return if labelInput.unitString.isEmpty {
                        Text(labelInput.valueString)
                    } else {
                        Text(verbatim: "\(labelInput.valueString) \(labelInput.unitString)")
                    }
                }(),
                // Issue here is that, depending on the specific chart context, we sometimes don't actually want the time
                // (bc the chart entry is representing eg an entire day worth of data reduced into a single value...)
                // challenge ist that we can't easily pass around this context :/
                secondary: { () -> Text in
                    let cal = Calendar.current
                    let range = dataPoint.timeRange
                    return if cal.isDate(range.lowerBound, inSameDayAs: range.upperBound)
                        || range.upperBound.timeIntervalSince(range.lowerBound) < TimeConstants.hour * 12 {
                        Text(range.middle.formatted(Date.FormatStyle(date: .numeric, time: .omitted)))
                    } else {
                        Text(range.displayText())
                    }
                }()
            )
        }
    }
    
    let timeRange: Range<Date>
    let value: Double
    
    init(timeRange: Range<Date>, value: Double) {
        self.timeRange = timeRange
        self.value = value
    }
    
    // periphery:ignore - API
    init(date: Date, value: Double) {
        self.init(
            timeRange: date..<date,
            value: value
        )
    }
}


protocol HealthStatsChartDataSetProtocol<Data> {
    associatedtype Data: RandomAccessCollection
    associatedtype ID: Hashable
    
    typealias MakeHighlightConfig = @Sendable (
        _ dataSet: any HealthStatsChartDataSetProtocol,
        _ dataPoint: HealthStatsChartDataPoint
    ) -> HealthStatsChartDataPoint.HighlightConfiguration
    
    var name: String { get }
    var sampleType: MHCQuantitySampleType { get }
    var drawingConfig: ChartDataSetDrawingConfig { get }
    var data: Data { get }
    var id: KeyPath<Data.Element, ID> { get }
    var makeDataPoint: (Data.Element) -> HealthStatsChartDataPoint? { get }
    var makeHighlightConfig: MakeHighlightConfig { get }
}


struct HealthStatsChartDataSet<Data: RandomAccessCollection, ID: Hashable>: HealthStatsChartDataSetProtocol {
    let name: String
    let sampleType: MHCQuantitySampleType
    let drawingConfig: ChartDataSetDrawingConfig
    let data: Data
    let id: KeyPath<Data.Element, ID>
    let makeDataPoint: (Data.Element) -> HealthStatsChartDataPoint?
    let makeHighlightConfig: MakeHighlightConfig
    
    init(
        name: String,
        sampleType: MHCQuantitySampleType,
        drawingConfig: ChartDataSetDrawingConfig,
        data: Data,
        id: KeyPath<Data.Element, ID>,
        makeDataPoint: @escaping (Data.Element) -> HealthStatsChartDataPoint?,
        makeHighlightConfig: @escaping MakeHighlightConfig
    ) {
        self.name = name
        self.sampleType = sampleType
        self.drawingConfig = drawingConfig
        self.data = data
        self.id = id
        self.makeDataPoint = makeDataPoint
        self.makeHighlightConfig = makeHighlightConfig
    }
    
    init(
        name: String,
        sampleType: MHCQuantitySampleType,
        drawingConfig: ChartDataSetDrawingConfig,
        dataPoints: Data,
        makeHighlightConfig: @escaping MakeHighlightConfig
    ) where Data.Element == HealthStatsChartDataPoint, ID == HealthStatsChartDataPoint {
        self.init(
            name: name,
            sampleType: sampleType,
            drawingConfig: drawingConfig,
            data: dataPoints,
            id: \.self,
            makeDataPoint: { $0 },
            makeHighlightConfig: makeHighlightConfig
        )
    }
}


struct HealthStatsChart<each DataSet: HealthStatsChartDataSetProtocol>: View {
    @Environment(\.calendar)
    private var calendar
    @Environment(\.healthStatsChartHoverHighlightEnabled)
    private var enableHoverHighlight
    
    private let dataSet: (repeat each DataSet)
    
    @State private var xSelection: Date?
    
    private var hasData: Bool {
        for dataSet in repeat each dataSet {
            if !dataSet.data.isEmpty { // swiftlint:disable:this for_where
                return true
            }
        }
        return false
    }
    
    var body: some View {
        chart
            .chartOverlay { _ in
                if !hasData {
                    Text("No Data")
                        .foregroundStyle(.secondary)
                }
            }
    }
    
    @ViewBuilder private var chart: some View {
        Chart {
            chartContent
        }
        .chartLegend(.hidden)
        .if(enableHoverHighlight) {
            $0.chartXSelection(value: $xSelection)
        }
        .chartYAxis {
            AxisMarks(values: .automatic(desiredCount: 3))
        }
    }
    
    
    @ChartContentBuilder private var chartContent: some ChartContent {
        ChartContentBuilder.buildBlock(repeat buildContent(for: each dataSet))
        if enableHoverHighlight,
           let xSelection,
           case let dataPoints = xAxisSelectionDataPoints(for: xSelection),
           let (dataSet, dataPoint) = dataPoints.last {
            ChartHighlightRuleMark(
                x: .value("Selection", xSelection, unit: .day, calendar: calendar),
                config: dataSet.makeHighlightConfig(dataSet, dataPoint)
            )
        }
    }
    
    init(_ dataSet: repeat each DataSet) {
        self.dataSet = (repeat each dataSet)
    }
    
    @ChartContentBuilder
    private func buildContent(for dataSet: some HealthStatsChartDataSetProtocol) -> some ChartContent {
        ForEach(dataSet.data, id: dataSet.id) { element in
            if let dataPoint = dataSet.makeDataPoint(element) {
                chartContent(for: dataPoint, in: dataSet)
            }
        }
    }
    
    @ChartContentBuilder
    private func chartContent(for dataPoint: HealthStatsChartDataPoint, in dataSet: some HealthStatsChartDataSetProtocol) -> some ChartContent {
        let xVal: PlottableValue = .value("Date", dataPoint.timeRange)
        let yVal: PlottableValue = .value(dataSet.name, dataPoint.value)
        let series: PlottableValue = .value("Series", dataSet.name)
        SomeChartContent {
            switch dataSet.drawingConfig.chartType {
            case let .line(interpolationMethod):
                LineMark(x: xVal, y: yVal, series: series)
                    .interpolationMethod(interpolationMethod)
                PointMark(x: xVal, y: yVal)
                    .symbolSize(10)
            case .bar:
                BarMark(x: xVal, y: yVal)
            case let .point(area):
                PointMark(x: xVal, y: yVal)
                    .if(area) { $1.symbolSize($0) }
            }
        }
        .foregroundStyle(dataSet.drawingConfig.color)
    }
    
    private func xAxisSelectionDataPoints(for selection: Date) -> [(any HealthStatsChartDataSetProtocol, HealthStatsChartDataPoint)] {
        var retval: [(any HealthStatsChartDataSetProtocol, HealthStatsChartDataPoint)] = []
        for dataSet in repeat each dataSet {
            let dataPoints = dataSet.data.lazy.compactMap(dataSet.makeDataPoint)
            for dataPoint in dataPoints.filter({ $0.timeRange.contains(selection) }) {
                retval.append((dataSet, dataPoint))
            }
        }
        return retval
    }
}


// MARK: Environment Values

extension EnvironmentValues {
    @Entry fileprivate var healthStatsChartHoverHighlightEnabled: Bool = false
}

extension View {
    func healthStatsChartHoverHighlightEnabled(_ isEnabled: Bool = true) -> some View {
        self.environment(\.healthStatsChartHoverHighlightEnabled, isEnabled)
    }
}


// MARK: Other


private struct ChartXAxisModifier: ViewModifier {
    private enum MarksStride {
        case day
        case week
        case fortnight
        case month
        case quarter
        
        var dateCalc: (count: Int, component: Calendar.Component) {
            switch self {
            case .day:
                (1, .day)
            case .week:
                (1, .weekOfYear)
            case .fortnight:
                (2, .weekOfYear)
            case .month:
                (1, .month)
            case .quarter:
                (3, .month)
            }
        }
        
        func format(for date: Date, prev: Date, using cal: Calendar) -> Date.FormatStyle {
            let baseStyleNoTime: Date.FormatStyle = .dateTime.calendar(cal).omittingTime()
            return switch self {
            case .day, .week, .fortnight:
                baseStyleNoTime
                    .month(cal.isDate(date, equalTo: prev, toGranularity: .month) ? .omitted : .abbreviated)
                    .year(cal.isDate(date, equalTo: prev, toGranularity: .year) ? .omitted : .defaultDigits)
            case .month, .quarter:
                baseStyleNoTime
                    .day(.omitted)
                    .month(.abbreviated)
                    .year(cal.isDate(date, equalTo: prev, toGranularity: .year) ? .omitted : .defaultDigits)
            }
        }
    }
    
    @Environment(\.calendar)
    private var cal
    
    let timeRange: Range<Date>
    
    func body(content: Content) -> some View {
        content.chartXAxis {
            let duration = timeRange.timeInterval
            let stride: MarksStride = if duration <= TimeConstants.week * 2 {
                .day
            } else if duration <= TimeConstants.month {
                .week
            } else if duration <= TimeConstants.month * 3 {
                .fortnight
            } else if duration <= TimeConstants.month * 6 {
                .month
            } else {
                .quarter
            }
            let strideCalc = stride.dateCalc
            AxisMarks(values: .stride(by: strideCalc.component, count: strideCalc.count, calendar: cal)) { value in
                if let date = value.as(Date.self) {
                    if let prevDate = cal.date(byAdding: strideCalc.component, value: -strideCalc.count, to: date) {
                        AxisValueLabel(format: stride.format(for: date, prev: prevDate, using: cal))
                    } else {
                        AxisValueLabel(format: .dateTime.omittingTime())
                    }
                }
                AxisGridLine()
                AxisTick()
            }
        }
    }
}


extension View {
    func configureChartXAxis(for timeRange: Range<Date>) -> some View {
        self.modifier(ChartXAxisModifier(timeRange: timeRange))
    }
}
