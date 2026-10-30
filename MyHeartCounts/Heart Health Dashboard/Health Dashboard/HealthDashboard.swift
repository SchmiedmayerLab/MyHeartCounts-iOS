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
import GroveHealthKit
import GroveHealthKitUI
import HealthKit
import SwiftUI


extension Gradient {
    static let redToGreen = Gradient(colors: [.red, .orange, .yellow, .green])
}


enum HealthDashboardConstants {
    static let gridComponentCornerRadius: Double = 28
}

extension EnvironmentValues {
    @Entry var isRecentValuesViewInDetailedStatsSheet: Bool = false
}


/// creates a component view for use in the health dashboard, appropriate for the specific input's sample type and context
@ViewBuilder
@MainActor
func healthDashboardComponentView(
    for config: DefaultHealthDashboardTile.DisplayConfig,
    accessory: DefaultHealthDashboardTile.Accessory = .none
) -> some View {
    switch config.dataSource {
    case .healthKit(.quantity(.bloodGlucose)):
        DefaultHealthDashboardTile(queryInput: .bloodGlucose, config: config, accessory: accessory)
    case .healthKit(.quantity(let sampleType)):
        if let metric = HealthStatsMetric(sampleType) {
            DefaultHealthDashboardTile(queryInput: .statsDocuments(metric), config: config, accessory: accessory)
        } else {
            EmptyView()
        }
    case .firebase(let sampleType):
        DefaultHealthDashboardTile(queryInput: .firestore(sampleType), config: config, accessory: accessory)
    case .healthKit(.category(.sleepAnalysis)):
        LargeSleepAnalysisTile(timeRange: config.timeRange, accessory: .init(accessory))
    case .healthKit(.correlation(.bloodPressure)):
        LargeBloodPressureTile(timeRange: config.timeRange, accessory: .init(accessory))
    case .healthKit:
        // we shouldn't end up in here; no call site constructs a config for any other sample type
        EmptyView()
    }
}


extension GroveHealthKitUI.StatisticsAggregationOption {
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
