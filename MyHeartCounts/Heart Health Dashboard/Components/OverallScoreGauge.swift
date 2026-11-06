//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import SwiftUI


/// Displays the composite CVH score.
struct OverallScoreGauge: View {
    /// The composite score, in the range of `0...1`. `nil` if no score is available.
    let score: Double?
    
    private var valueAvailable: Bool {
        !(score?.isNaN ?? true)
    }
    
    var body: some View {
        Gauge(
            lineWidth: .relative(2),
            gradient: valueAvailable ? .redToGreen : Gradient(colors: [.gray]),
            progress: score
        ) {
            if let score, !score.isNaN {
                if #available(iOS 26.0, *) {
                    Text(Int(score * 100), format: .number)
                        .font(.largeTitle.scaled(by: 1.2).bold())
                } else {
                    Text(Int(score * 100), format: .number)
                        .font(.largeTitle.bold())
                }
            } else {
                Text("—")
                    .font(.largeTitle.bold())
                    .foregroundStyle(.secondary)
            }
        } minimumValueText: {
            Text("  0")
                .foregroundStyle(valueAvailable ? .primary : .secondary)
        } maximumValueText: {
            Text("100 ")
                .foregroundStyle(valueAvailable ? .primary : .secondary)
        }
        .frame(width: 140, height: 140)
    }
}
