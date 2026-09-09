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
import HealthKit
import MyHeartCountsShared
import SpeziFoundation
import SpeziHealthKit
import SpeziHealthKitUI
import SpeziViews
import SwiftUI


/// Grid Cell intended for usage in the ``HealthDashboard``, with support for most (quantity-based) sample types.
struct DefaultHealthDashboardTile: View {
    enum QueryInput {
        /// Temporary HealthKit-backed history until blood glucose moves to the fasting/A1c sample types.
        case bloodGlucose
        case firestore(CustomQuantitySampleType)
        /// fetch the data from the server-side stats documents (see ``StatsDocumentsQuery``)
        case statsDocuments(HealthStatsMetric)
    }
    
    enum Accessory {
        case none
        case timeRangeSelector(Binding<DetailedHealthStatsView.ChartTimeRange>)
    }
    
    /// The config of a component that displays a Quantity fetched from eg HealthKit.
    struct DisplayConfig: Sendable {
        let dataSource: DataSource
        let timeRange: HealthKitQueryTimeRange
        let chartConfig: ChartConfig
    }
    
    let queryInput: QueryInput
    let config: DisplayConfig
    let accessory: Accessory
    
    var body: some View {
        switch queryInput {
        case .bloodGlucose:
            bloodGlucoseView
        case .firestore(let sampleType):
            view(for: sampleType)
        case .statsDocuments(let metric):
            view(for: metric)
        }
    }
    
    private var aggregationStrategy: QuantitySamplesAggregationStrategy {
        switch queryInput {
        case .bloodGlucose:
            return .init(
                kind: .avg,
                interval: config.chartConfig.aggregationInterval
            )
        case .statsDocuments(let metric):
            return .init(
                kind: .init(metric.sampleType.hkSampleType.aggregationStyle),
                interval: config.chartConfig.aggregationInterval
            )
        case .firestore(let sampleType):
            return .init(
                kind: sampleType.aggregationKind,
                interval: config.chartConfig.aggregationInterval
            )
        }
    }
    
    private var bloodGlucoseView: some View {
        SamplesProviderView(
            input: .bloodGlucose,
            aggregationMode: aggregationStrategy,
            timeRange: config.timeRange
        ) { samples in
            innerView(for: samples, sampleType: .healthKit(.bloodGlucose))
        }
    }

    private func view(for metric: HealthStatsMetric) -> some View {
        SamplesProviderView(
            input: .statsDocuments(metric),
            aggregationMode: aggregationStrategy,
            timeRange: config.timeRange
        ) { samples in
            innerView(for: samples, sampleType: .healthKit(metric.sampleType))
        }
    }
    
    private func view(for sampleType: CustomQuantitySampleType) -> some View {
        SamplesProviderView(
            input: .firestore(sampleType),
            aggregationMode: aggregationStrategy,
            timeRange: config.timeRange
        ) { samples in
            innerView(for: samples, sampleType: .custom(sampleType))
        }
    }
    
    private func innerView(for samples: [QuantitySample], sampleType: QuantitySample.SampleType) -> some View {
        TileImpl(
            sampleType: sampleType,
            samples: samples,
            timeRange: self.config.timeRange,
            chartConfig: config.chartConfig,
            accessory: accessory
        )
    }
}


private struct TileImpl: View {
    private let sampleType: QuantitySample.SampleType
    private let samples: [QuantitySample]
    private let timeRange: HealthKitQueryTimeRange
    private let chartConfig: DefaultHealthDashboardTile.ChartConfig
    private let accessory: DefaultHealthDashboardTile.Accessory
    
    var body: some View {
        HealthDashboardTile(title: sampleType.displayTitle) {
            switch accessory {
            case .none:
                EmptyView()
            case .timeRangeSelector(let binding):
                ChartTimeRangePicker(timeRange: binding)
            }
        } content: {
            let drawingConfig = ChartDataSetDrawingConfig(
                chartType: chartConfig.chartType,
                color: sampleType.preferredTintColorForDisplay ?? .blue
            )
            let dataSet = HealthStatsChartDataSet(
                name: sampleType.displayTitle,
                sampleType: sampleType,
                drawingConfig: drawingConfig,
                data: samples,
                id: \.id
            ) { (sample: QuantitySample) in
                HealthStatsChartDataPoint(
                    timeRange: sample.startDate..<sample.endDate,
                    value: sample.value(as: sample.sampleType.displayUnit)
                )
            } makeHighlightConfig: { dataSet, dataPoint in
                .default(for: dataPoint, in: dataSet)
            }
            HealthStatsChart(dataSet)
                .chartXScale(domain: [timeRange.range.lowerBound, timeRange.range.upperBound])
                .configureChartXAxis(for: timeRange.range)
        }
    }
    
    fileprivate init(
        sampleType: QuantitySample.SampleType,
        samples: [QuantitySample],
        timeRange: HealthKitQueryTimeRange,
        chartConfig: DefaultHealthDashboardTile.ChartConfig,
        accessory: DefaultHealthDashboardTile.Accessory
    ) {
        self.sampleType = sampleType
        self.samples = samples
        self.timeRange = timeRange
        self.chartConfig = chartConfig
        self.accessory = accessory
    }
}


// MARK: SamplesProviderView

private struct SamplesProviderView<Content: View>: View {
    @Environment(\.calendar)
    private var calendar
    private let input: DefaultHealthDashboardTile.QueryInput
    private let aggregationMode: QuantitySamplesAggregationStrategy
    private let timeRange: HealthKitQueryTimeRange
    private let content: @MainActor ([QuantitySample]) -> Content
    
    var body: some View {
        switch input {
        case .bloodGlucose:
            BloodGlucoseImpl(
                statistics: .init(.bloodGlucose, aggregatedBy: [.average], over: aggregationMode.interval, timeRange: timeRange),
                content: content
            )
        case .firestore(let sampleType):
            FirestoreImpl(
                samples: .init(sampleType: sampleType, timeRange: timeRange),
                content: content
            )
        case .statsDocuments(let metric):
            StatsDocumentsImpl(
                samples: .init(
                    metric: metric,
                    timeRange: timeRange,
                    aggregationKind: aggregationMode.kind,
                    interval: .init(
                        interval: aggregationMode.interval,
                        anchor: calendar.startOfDay(for: timeRange.range.lowerBound),
                        calendar: calendar,
                        alignmentPolicy: .approximate
                    )
                ),
                content: content
            )
        }
    }
    
    init(
        input: DefaultHealthDashboardTile.QueryInput,
        aggregationMode: QuantitySamplesAggregationStrategy,
        timeRange: HealthKitQueryTimeRange,
        @ViewBuilder content: @escaping @MainActor ([QuantitySample]) -> Content
    ) {
        self.input = input
        self.aggregationMode = aggregationMode
        self.timeRange = timeRange
        self.content = content
    }
}


extension SamplesProviderView {
    private struct BloodGlucoseImpl: View {
        @HealthKitStatisticsQuery var statistics: [HKStatistics]
        let content: @MainActor ([QuantitySample]) -> Content

        var body: some View {
            content(statistics.compactMap { statistics in
                statistics.averageQuantity().map { quantity in
                    QuantitySample(
                        id: UUID(),
                        sampleType: .healthKit(.bloodGlucose),
                        quantity: quantity,
                        startDate: statistics.startDate,
                        endDate: statistics.endDate
                    )
                }
            })
        }
    }

    private struct StatsDocumentsImpl: View {
        @StatsDocumentsQuery<QuantitySample> var samples: [QuantitySample]
        let content: @MainActor ([QuantitySample]) -> Content
        
        var body: some View {
            content(samples)
        }
    }
    
    private struct FirestoreImpl: View {
        @MHCFirestoreQuery<QuantitySample> var samples: [QuantitySample]
        let content: @MainActor ([QuantitySample]) -> Content
        
        var body: some View {
            content(samples)
        }
    }
}
