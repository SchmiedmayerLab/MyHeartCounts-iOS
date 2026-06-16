//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

// swiftlint:disable file_types_order

import Charts
import Foundation
import SpeziHealthKit
import SpeziHealthKitUI
import SwiftUI


extension Gradient {
    static let redToGreen = Gradient(colors: [.red, .orange, .yellow, .green])
}


enum HealthDashboardConstants {}

typealias HealthDashboardGoalProvider = @Sendable @MainActor (QuantitySample.SampleType) -> LegacyAchievement.ResolvedGoal?

extension EnvironmentValues {
    @Entry var healthDashboardGoalProvider: HealthDashboardGoalProvider?
    @Entry var isRecentValuesViewInDetailedStatsSheet: Bool = false
}


/// creates a component view for use in the health dashboard, appropriate for the specific input's sample type and context
@ViewBuilder
@MainActor
func healthDashboardComponentView(
    for config: HealthDashboardLayout.GridComponent.ComponentDisplayConfig,
    withSize size: HealthDashboardLayout.ComponentSize,
    accessory: DefaultHealthDashboardTile.Accessory = .none
) -> some View {
    switch (size, config.dataSource) {
    case (_, .healthKit(.quantity(let sampleType))):
        DefaultHealthDashboardTile(queryInput: .healthKit(sampleType), config: config, accessory: accessory)
    case (_, .firebase(let sampleType)):
        DefaultHealthDashboardTile(queryInput: .firestore(sampleType), config: config, accessory: accessory)
    case (.small, .healthKit(.category(.sleepAnalysis))):
        SmallSleepAnalysisTile()
    case (.large, .healthKit(.category(.sleepAnalysis))):
        LargeSleepAnalysisTile(timeRange: config.timeRange, accessory: .init(accessory))
    case (.small, .healthKit(.correlation(.bloodPressure))):
        SmallBloodPressureTile()
    case (.large, .healthKit(.correlation(.bloodPressure))):
        LargeBloodPressureTile(timeRange: config.timeRange, accessory: .init(accessory))
    case (_, .healthKit):
        // we shouldn't end up in here, since the GridComponent factory methods limit which HealthKit sample types are allowed here...
        EmptyView()
    }
}


struct HealthDashboard: View {
    typealias SelectionHandler = @MainActor (SelectionHandlerInput) -> Void
    enum SelectionHandlerInput {
        case healthKit(SampleTypeProxy)
        case customQuantitySample(CustomQuantitySampleType)
    }
    
    private let layout: HealthDashboardLayout
    private let goalProvider: HealthDashboardGoalProvider?
    private let selectionHandler: SelectionHandler?
    
    var body: some View {
        Group {
            ForEach(0..<layout.blocks.endIndex, id: \.self) { blockIdx in
                let block = layout.blocks[blockIdx]
                Section {
                    switch block.content {
                    case .grid(let components):
                        makeGrid(with: components)
                    case .largeChart(let component):
                        healthDashboardComponentView(
                            for: .init(
                                dataSource: component.dataSource,
                                timeRange: component.timeRange,
                                style: .chart(component.chartConfig),
                                enableSelection: false
                            ),
                            withSize: .large
                        )
                    case .largeCustom(let makeView):
                        makeView()
                    }
                } header: {
                    if let title = block.title {
                        Text(title)
                            .padding(.horizontal)
                            .padding(.bottom, 7)
                    }
                } footer: {
                    if let footer = block.footer {
                        Text(footer)
                            .padding()
                    }
                }
                .listRowInsets(.zero)
                .listRowBackground(Color.clear)
            }
        }
        .environment(\.healthDashboardGoalProvider, goalProvider)
    }
    
    
    init(
        layout: HealthDashboardLayout,
        goalProvider: HealthDashboardGoalProvider? = nil,
        selectionHandler: SelectionHandler? = nil
    ) {
        self.layout = layout
        self.goalProvider = goalProvider
        self.selectionHandler = selectionHandler
    }
    
    
    @ViewBuilder
    private func makeGrid(with components: [HealthDashboardLayout.GridComponent]) -> some View {
        let columns = [
            GridItem(.flexible(), spacing: 12, alignment: .top),
            GridItem(.flexible(), alignment: .top)
        ]
        LazyVGrid(columns: columns, alignment: .center, spacing: 12, pinnedViews: .sectionHeaders) {
            ForEach(0..<components.endIndex, id: \.self) { idx in
                makeView(for: components[idx])
                    .clipShape(RoundedRectangle(cornerRadius: HealthDashboardConstants.gridComponentCornerRadius))
                    .frame(maxHeight: 178)
            }
        }
    }
    
    
    @ViewBuilder
    private func makeView(for component: HealthDashboardLayout.GridComponent) -> some View {
        let view = Group {
            switch component {
            case .quantityDisplay(let config):
                healthDashboardComponentView(for: config, withSize: .small)
            case .custom(let config):
                HealthDashboardTile(title: config.title, headerInsets: config.headerInsets) {
                    config.content()
                }
            }
        }
        let tapAction = { () -> (@MainActor () -> Void)? in
            switch component {
            case .quantityDisplay(let config):
                if config.enableSelection, let selectionHandler {
                    switch config.dataSource {
                    case .healthKit(let sampleType):
                        { @MainActor in
                            selectionHandler(.healthKit(sampleType))
                        }
                    case .firebase(let sampleType):
                        { @MainActor in
                            selectionHandler(.customQuantitySample(sampleType))
                        }
                    }
                } else {
                    nil
                }
            case .custom(let config):
                config.tapAction
            }
        }()
        if let tapAction {
            Button(action: tapAction) {
                view.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel({ () -> String in
                switch component {
                case .quantityDisplay(let config):
                    config.dataSource.sampleTypeDisplayTitle
                case .custom(let config):
                    config.title
                }
            }())
            .accessibilityIdentifier("MHC:DashboardTile:\(component.accessibilityIdentifier)")
        } else {
            view
        }
    }
}


extension HealthDashboardLayout.GridComponent {
    var accessibilityIdentifier: String {
        switch self {
        case .quantityDisplay(let config):
            config.dataSource.sampleTypeDisplayTitle(in: .enUS)
        case .custom(let config):
            config.accessibilityIdentifier ?? config.title
        }
    }
}


extension SpeziHealthKitUI.StatisticsAggregationOption {
    init(_ other: HKQuantityAggregationStyle) {
        switch other {
        case .cumulative:
            self = .sum
        case .discreteArithmetic, .discreteTemporallyWeighted:
            self = .avg
        case .discreteEquivalentContinuousLevel:
            fatalError("Currently not supported")
        @unknown default:
            fatalError("Currently not supported")
        }
    }
    
    init(_ sampleType: MHCQuantitySampleType) {
        switch sampleType {
        case .healthKit(let sampleType):
            self.init(sampleType.hkSampleType.aggregationStyle)
        case .custom(let sampleType):
            self = sampleType.aggregationKind
        }
    }
}


enum TimeConstants {
    static let minute: TimeInterval = 60
    static let hour = 60 * minute
    static let day = 24 * hour
    static let week = 7 * day
    static let month = 31 * day
    static let year = 365 * day
}


extension FloatingPoint {
    var isWholeNumber: Bool {
        rounded().isEqual(to: self)
    }
}


extension HKCorrelation {
    func firstSample<Sample>(ofType sampleType: SampleType<Sample>) -> Sample? {
        for sample in self.objects {
            if let sample = sample as? Sample, sample.is(sampleType) {
                return sample
            }
        }
        return nil
    }
}


extension AnySampleType {
    var preferredTintColorForDisplay: Color? {
        switch SampleTypeProxy(self) {
        case .heartRate, .activeEnergyBurned:
            Color.red
        case .bloodOxygen:
            Color.blue
        case .bloodPressure, .bloodPressureSystolic, .bloodPressureDiastolic:
            Color.red
        case .stepCount, .walkingStepLength, .distanceWalkingRunning, .runningStrideLength,
                .stairAscentSpeed, .stairDescentSpeed,
                .walkingAsymmetryPercentage, .walkingDoubleSupportPercentage:
            Color.orange
        default:
            nil
        }
    }
}


extension QuantitySample.SampleType {
    var preferredTintColorForDisplay: Color? {
        switch self {
        case .healthKit(let sampleType):
            sampleType.preferredTintColorForDisplay
        case .custom(let sampleType):
            sampleType.preferredTintColor
        }
    }
}


extension HealthKitStatisticsQuery.AggregationInterval {
    static func `for`(_ queryTimeRange: HealthKitQueryTimeRange, in calendar: Calendar) -> Self {
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: queryTimeRange.range.lowerBound,
            to: queryTimeRange.range.upperBound
        )
        return .init(components)
    }
}
