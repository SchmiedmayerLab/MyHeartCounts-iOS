//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

// swiftlint:disable type_contents_order
// periphery:ignore:all - parts of the API simply are unused, but we want to keep them around for the future.

import Foundation
import GroveFoundation
import GroveHealthKit
import GroveHealthKitUI
import MyHeartCountsShared
import SwiftUI


struct HealthDashboardLayout: Sendable {
    var blocks: [Block]
    
    init(blocks: some Collection<Block> = []) {
        self.blocks = Array(blocks)
    }
    
    init(@ArrayBuilder<Block> blocks: () -> [Block]) {
        self.init(blocks: blocks())
    }
}


extension HealthDashboardLayout {
    enum ComponentSize {
        case large
        case small
    }
    
    struct Block: Sendable {
        enum Content: Sendable {
            case largeChart(LargeChartComponent)
            case largeCustom(@MainActor () -> AnyView)
            case grid([GridComponent])
        }
        
        let title: LocalizedStringResource?
        let footer: LocalizedStringResource?
        let content: Content
        
        private init(title: LocalizedStringResource?, footer: LocalizedStringResource?, content: Content) {
            self.title = title
            self.footer = footer
            self.content = content
        }
        
        static func largeChart(
            sectionTitle: LocalizedStringResource? = nil,
            footer: LocalizedStringResource? = nil,
            component: LargeChartComponent
        ) -> Self {
            .init(title: sectionTitle, footer: footer, content: .largeChart(component))
        }
        
        static func large(
            sectionTitle: LocalizedStringResource? = nil,
            footer: LocalizedStringResource? = nil,
            @ViewBuilder content: @MainActor @escaping () -> some View
        ) -> Self {
            .init(title: sectionTitle, footer: footer, content: .largeCustom {
                content().intoAnyView()
            })
        }
        
        static func grid(
            sectionTitle: LocalizedStringResource? = nil,
            footer: LocalizedStringResource? = nil,
            components: [GridComponent]
        ) -> Self {
            .init(title: sectionTitle, footer: footer, content: .grid(components))
        }
        
        static func grid(
            sectionTitle: LocalizedStringResource? = nil,
            footer: LocalizedStringResource? = nil,
            @ArrayBuilder<GridComponent> components: () -> [GridComponent]
        ) -> Self {
            .init(title: sectionTitle, footer: footer, content: .grid(components()))
        }
    }
}


// MARK: Styles and related Configs

extension HealthDashboardLayout {
    enum Style: Sendable {
        case singleValue(SingleValueConfig)
        case chart(ChartConfig)
        /// How the gauge's "current value" should be determined
        case gauge(_ value: SingleValueConfig, score: ScoreDefinition)
        
        func effectiveAggregationKind(for sampleType: MHCQuantitySampleType) -> StatisticsAggregationOption {
            switch self {
            case .chart:
                StatisticsAggregationOption(sampleType)
            case .singleValue(let config), .gauge(let config, score: _):
                config.effectiveAggregationKind ?? .init(sampleType)
            }
        }
    }
    
    struct SingleValueConfig: Sendable {
        enum _Variant: Sendable { // swiftlint:disable:this type_name
            case mostRecentSample
            case aggregated([QuantitySamplesAggregationStrategy], StatisticsAggregationOption?)
        }
        
        let _variant: _Variant // swiftlint:disable:this identifier_name
        
        fileprivate var effectiveAggregationKind: StatisticsAggregationOption? {
            switch _variant {
            case .mostRecentSample:
                nil
            case let .aggregated(steps, final):
                final ?? steps.last!.kind // swiftlint:disable:this force_unwrapping
            }
        }
        
        static var mostRecentSample: Self {
            .init(_variant: .mostRecentSample)
        }
        
        private init(_variant: _Variant) { // swiftlint:disable:this identifier_name
            self._variant = _variant
        }
        
        static func aggregated(_ kind: StatisticsAggregationOption) -> Self {
            .init(_variant: .aggregated([], kind))
        }
        
        static func aggregated(_ strategy1: QuantitySamplesAggregationStrategy, _ additional: QuantitySamplesAggregationStrategy...) -> Self {
            .init(_variant: .aggregated([strategy1].appending(contentsOf: additional), nil))
        }
        
        static func aggregated(
            _ start: QuantitySamplesAggregationStrategy,
            _ final: StatisticsAggregationOption
        ) -> Self {
            .aggregated(start, final: final)
        }
        
        static func aggregated(
            _ start: QuantitySamplesAggregationStrategy,
            _ then: QuantitySamplesAggregationStrategy...,
            final: StatisticsAggregationOption
        ) -> Self {
            .init(_variant: .aggregated([start].appending(contentsOf: then), final))
        }
    }
    
    
    struct ChartConfig: Sendable {
        let chartType: ChartDataSetDrawingConfig.ChartType
        let aggregationInterval: HealthKitStatisticsQuery.AggregationInterval
        
        init(chartType: ChartDataSetDrawingConfig.ChartType, aggregationInterval: HealthKitStatisticsQuery.AggregationInterval) {
            self.chartType = chartType
            self.aggregationInterval = aggregationInterval
        }
        
        init(chartType: ChartDataSetDrawingConfig.ChartType, defaultAggregationIntervalFor timeRange: HealthKitQueryTimeRange) {
            self.init(chartType: chartType, aggregationInterval: Self.defaultSmallChartAggregationInterval(for: timeRange))
        }
        
        static func `default`(for sampleType: SampleType<HKQuantitySample>, in timeRange: HealthKitQueryTimeRange) -> Self {
            let defaultAggIterval = defaultSmallChartAggregationInterval(for: timeRange)
            return switch sampleType {
            case .stepCount, .activeEnergyBurned:
                .init(chartType: .bar, aggregationInterval: defaultAggIterval)
            case .distanceWalkingRunning:
                .init(chartType: .line(), aggregationInterval: defaultAggIterval)
            case .heartRate:
                .init(chartType: .point(), aggregationInterval: .init(.init(minute: 15)))
            case .bloodOxygen:
                .init(chartType: .point(), aggregationInterval: defaultAggIterval)
            default:
                .init(chartType: .line(), aggregationInterval: defaultAggIterval)
            }
        }
        
        private static func defaultSmallChartAggregationInterval(
            for timeRange: HealthKitQueryTimeRange
        ) -> HealthKitStatisticsQuery.AggregationInterval {
            let duration = timeRange.duration
            return if duration <= TimeConstants.hour {
                HealthKitStatisticsQuery.AggregationInterval(.init(minute: 15))
            } else if duration <= TimeConstants.day / 2 {
                .init(.init(hour: 2))
            } else if duration <= TimeConstants.day {
                .hour
            } else if duration <= TimeConstants.day * 4 {
                .init(.init(hour: 12))
            } else if duration <= TimeConstants.week * 2 {
                .day
            } else if duration <= TimeConstants.month {
                .init(.init(day: 2))
            } else {
                .week
            }
        }
    }
    
    struct AutomaticChartConfig {
        static let automatic = Self()
        private init() {}
    }
    
    enum DataSource: Sendable {
        case healthKit(SampleTypeProxy)
        case firebase(CustomQuantitySampleType)
        
        var asMHCSampleType: MHCSampleType {
            switch self {
            case .healthKit(let sampleType): .healthKit(sampleType)
            case .firebase(let sampleType): .custom(sampleType)
            }
        }
        
        var sampleTypeDisplayTitle: String {
            asMHCSampleType.displayTitle
        }
        
        func sampleTypeDisplayTitle(in locale: Locale) -> String {
            asMHCSampleType.displayTitle(in: locale)
        }
    }
    
    
    struct LargeChartComponent: Sendable {
        let dataSource: DataSource
        let timeRange: HealthKitQueryTimeRange
        let chartConfig: ChartConfig
        
        private init(dataSource: DataSource, timeRange: HealthKitQueryTimeRange, chartConfig: ChartConfig) {
            self.dataSource = dataSource
            self.timeRange = timeRange
            self.chartConfig = chartConfig
        }
        
        init(sampleType: SampleType<HKQuantitySample>, timeRange: HealthKitQueryTimeRange, chartConfig: ChartConfig) {
            self.init(dataSource: .healthKit(SampleTypeProxy(sampleType)), timeRange: timeRange, chartConfig: chartConfig)
        }
        init(sampleType: SampleType<HKQuantitySample>, timeRange: HealthKitQueryTimeRange, chartConfig: AutomaticChartConfig) {
            self.init(
                dataSource: .healthKit(SampleTypeProxy(sampleType)),
                timeRange: timeRange,
                chartConfig: .default(for: sampleType, in: timeRange)
            )
        }
    }
    
    
    /// A Health Stat Component within a Grid Section
    enum GridComponent: Sendable {
        /// The config of a component that displays a Quantity fetched from eg HealthKit.
        struct ComponentDisplayConfig: Sendable {
            let dataSource: DataSource
            let timeRange: HealthKitQueryTimeRange
            let style: Style
            let enableSelection: Bool
        }
        
        /// The config of a component that displays a custom view.
        struct CustomComponentConfig: Sendable {
            let title: String
            let accessibilityIdentifier: String?
            let headerInsets: EdgeInsets
            let content: @MainActor () -> AnyView
            let tapAction: (@MainActor () -> Void)?
            
            fileprivate init(
                title: String,
                accessibilityIdentifier: String?,
                headerInsets: EdgeInsets,
                content: @MainActor @escaping () -> AnyView,
                tapAction: (@MainActor () -> Void)?
            ) {
                self.title = title
                self.accessibilityIdentifier = accessibilityIdentifier
                self.headerInsets = headerInsets
                self.content = content
                self.tapAction = tapAction
            }
        }
        
        case quantityDisplay(ComponentDisplayConfig) // technically wrong since it's also used for some (select) non-quantity types...
        case custom(CustomComponentConfig)
        
        private init(dataSource: DataSource, timeRange: HealthKitQueryTimeRange, style: Style, enableSelection: Bool) {
            self = .quantityDisplay(.init(dataSource: dataSource, timeRange: timeRange, style: style, enableSelection: enableSelection))
        }
        
        /// Creates a new Component
        /// - parameter sampleType: The `SampleType` the component should visualise.
        /// - parameter timeRange: The time range for which the component should visualise data.
        /// - parameter chartConfig: Whether the component should use a chart to visualize its data, and what the chart should look like.
        init(
            _ sampleType: SampleType<HKQuantitySample>,
            timeRange: HealthKitQueryTimeRange = .today,
            style: Style,
            enableSelection: Bool = true
        ) {
            self = .quantityDisplay(.init(
                dataSource: .healthKit(SampleTypeProxy(sampleType)),
                timeRange: timeRange,
                style: style,
                enableSelection: enableSelection
            ))
        }
        
        static func bloodPressure(style: Style, enableSelection: Bool = true) -> Self {
            Self(dataSource: .healthKit(.init(.bloodPressure)), timeRange: .last(days: 2), style: style, enableSelection: enableSelection)
        }
        
        static func sleepAnalysis(style: Style, enableSelection: Bool = true) -> Self {
            Self(dataSource: .healthKit(.init(.sleepAnalysis)), timeRange: .last(days: 7), style: style, enableSelection: enableSelection)
        }
        
        static func custom(
            title: String,
            accessibilityIdentifier: String?,
            headerInsets: EdgeInsets = .zero,
            @ViewBuilder _ content: @MainActor @escaping () -> some View,
            onTap tapAction: (@MainActor () -> Void)? = nil
        ) -> Self {
            .custom(.init(
                title: title,
                accessibilityIdentifier: accessibilityIdentifier,
                headerInsets: headerInsets,
                content: { content().intoAnyView() },
                tapAction: tapAction
            ))
        }
    }
}


extension HealthDashboardLayout: ExpressibleByArrayLiteral {
    init(arrayLiteral elements: Block...) {
        self.init(blocks: elements)
    }
}
