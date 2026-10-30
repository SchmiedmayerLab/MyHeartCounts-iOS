//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveStudyDefinition
import SwiftUI


struct TimedWalkRunTestResultInfo: View {
    let result: TimedWalkingTestResult
    
    var body: some View {
        LabeledContent("Date", value: result.startDate, format: .dateTime)
        LabeledContent("Steps", value: result.numberOfSteps, format: .number)
        LabeledContent(
            "Distance",
            value: Measurement<UnitLength>(value: result.distanceCovered, unit: .meters),
            format: .measurement(width: .abbreviated)
        )
        switch result.test.kind {
        case .walking:
            let _ = () // swiftlint:disable:this redundant_discardable_let
        case .running:
            LabeledContent(
                "VO2MAX_ESTIMATE_LABEL",
                value: Measurement<UnitOxygenConsumption>(
                    value: (result.distanceCovered - 504.9) / 44.73,
                    unit: .mlPerKgPerMin
                ),
                format: .measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(...1)))
            )
        }
    }
}
