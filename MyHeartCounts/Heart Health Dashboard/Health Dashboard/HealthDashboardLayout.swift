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


// MARK: Dashboard Sections

/// A dashboard section displaying arbitrary content, with an optional title and footer.
struct HealthDashboardSection<Content: View>: View {
    private let title: LocalizedStringResource?
    private let footer: LocalizedStringResource?
    private let content: Content
    
    var body: some View {
        Section {
            content
        } header: {
            if let title {
                Text(title)
                    .padding(.horizontal)
                    .padding(.bottom, 7)
            }
        } footer: {
            if let footer {
                Text(footer)
                    .padding()
            }
        }
        .listRowInsets(.zero)
        .listRowBackground(Color.clear)
    }
    
    init(
        _ title: LocalizedStringResource? = nil,
        footer: LocalizedStringResource? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.footer = footer
        self.content = content()
    }
}


/// A dashboard section that lays its content out in a two-column grid, with an optional title and footer.
///
/// Intended to contain ``HealthDashboardGridTile``s.
struct HealthDashboardGridSection<Content: View>: View {
    private let title: LocalizedStringResource?
    private let footer: LocalizedStringResource?
    private let content: Content
    
    var body: some View {
        HealthDashboardSection(title, footer: footer) {
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 12, alignment: .top),
                    GridItem(.flexible(), alignment: .top)
                ],
                alignment: .center,
                spacing: 12,
                pinnedViews: .sectionHeaders
            ) {
                content
            }
        }
    }
    
    init(
        _ title: LocalizedStringResource? = nil,
        footer: LocalizedStringResource? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.footer = footer
        self.content = content()
    }
}


/// A tile within a ``HealthDashboardGridSection``.
struct HealthDashboardGridTile<Content: View>: View {
    private let title: String
    private let accessibilityIdentifier: String
    private let headerInsets: EdgeInsets
    private let tapAction: (@MainActor () -> Void)?
    private let content: Content
    
    var body: some View {
        Group {
            let tile = HealthDashboardTile(title: title, headerInsets: headerInsets) {
                content
            }
            if let tapAction {
                Button(action: tapAction) {
                    tile.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(title)
                .accessibilityIdentifier("MHC:DashboardTile:\(accessibilityIdentifier)")
            } else {
                tile
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: HealthDashboardConstants.gridComponentCornerRadius))
        .frame(maxHeight: 178)
    }
    
    init(
        title: String,
        accessibilityIdentifier: String? = nil,
        headerInsets: EdgeInsets = .zero,
        onTap tapAction: (@MainActor () -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.accessibilityIdentifier = accessibilityIdentifier ?? title
        self.headerInsets = headerInsets
        self.tapAction = tapAction
        self.content = content()
    }
}


// MARK: Tile Configs

extension DefaultHealthDashboardTile {
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
    
    
    enum DataSource: Sendable {
        case healthKit(SampleTypeProxy)
        case firebase(CustomQuantitySampleType)
    }
}
