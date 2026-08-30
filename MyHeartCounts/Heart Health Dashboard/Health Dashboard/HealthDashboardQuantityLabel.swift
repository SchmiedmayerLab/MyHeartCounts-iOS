//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

// swiftlint:disable file_types_order

import Foundation
import GroveHealthKit
import GroveViews
import MyHeartCountsShared
import SwiftUI


extension HealthDashboardConstants {
    static let gridComponentCornerRadius: Double = 28
}


struct HealthDashboardQuantityLabel: View {
    let input: Input
    
    var body: some View {
        VStack {
            Spacer()
            HStack(alignment: .lastTextBaseline, spacing: 3) {
                Text(input.valueString)
                    .font(.title.bold())
                Text(input.unitString)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            // NOTE: displaying the entire range (or even just the range's upper bound) here technically won't always be correct
            // (it's not incorrect either, just not perfect):
            // if we have a single-value grid cell that displays the max heart rate measured today, we'd have the label at the bottom say
            // "Today", even though displaying the precise time of this max heart rate measurement would be more correct.
            Text(input.timeRange.upperBound.shortDescription())
                .foregroundStyle(.secondary)
                .font(.footnote)
        }
    }
}


extension HealthDashboardQuantityLabel {
    struct Input {
        let value: Double?
        let valueString: String
        let unitString: String
        let timeRange: Range<Date>
        
        init(value: Double?, valueString: String, unit: HKUnit, timeRange: Range<Date>) {
            func unitString(for unit: HKUnit) -> String {
                if unit == .count() {
                    ""
                } else {
                    unit.unitString
                }
            }
            self.value = value
            self.valueString = valueString
            self.unitString = unitString(for: unit)
            self.timeRange = timeRange
        }
        
        init(value: Double, sampleType: MHCQuantitySampleType, timeRange: Range<Date>) {
            let valueString = switch sampleType {
            case .healthKit(.bloodOxygen):
                String(format: "%.1f", value / 100)
            case .healthKit(.walkingAsymmetryPercentage), .healthKit(.walkingDoubleSupportPercentage):
                String(format: "%.2f", value / 100)
            case .healthKit(.bodyMassIndex):
                String(format: "%.1f", value)
            case _ where sampleType.displayUnit == .count():
                Int(value).formatted(.number)
            default:
                if value.isWholeNumber {
                    Int(value).formatted(.number)
                } else {
                    String(format: "%.2f", value)
                }
            }
            self.init(
                value: value,
                valueString: valueString,
                unit: sampleType.displayUnit,
                timeRange: timeRange
            )
        }
    }
}
