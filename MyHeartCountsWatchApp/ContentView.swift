//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import GroveViews
import SwiftUI
import WatchKit


struct ContentView: View {
    @Environment(WorkoutManager.self)
    private var workoutManager
    
    var body: some View {
        switch workoutManager.state {
        case .idle:
            inactiveContent
        case .active(let timeRange):
            activeContent(expectedTimeRange: timeRange)
        }
    }
    
    @ViewBuilder private var inactiveContent: some View {
        VStack(alignment: .leading) {
            Text("My Heart Counts")
                .font(.system(size: 21, weight: .semibold))
            Color.clear
                .frame(height: 40)
            Text("Open the app on your iPhone to start a\nSix-Minute Walk Test")
                .font(.subheadline)
                .multilineTextAlignment(.leading)
        }
    }
    
    @ViewBuilder
    private func activeContent(expectedTimeRange: Range<Date>) -> some View {
        VStack(alignment: .leading) {
            Text("Test Ongoing")
                .font(.system(size: 21, weight: .semibold))
            Spacer()
            TimelineView(.periodic(from: expectedTimeRange.lowerBound, by: 1)) { context in
                let remaining = max(0, Int(expectedTimeRange.upperBound.timeIntervalSince(context.date)))
                let minutes = remaining / 60
                let seconds = remaining % 60
                Text(String(format: "%d:%02d", minutes, seconds))
                    .font(.system(size: 60, design: .rounded).bold())
                    .monospacedDigit()
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.easeInOut(duration: 0.2), value: remaining)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            Spacer()
            Text("See your iPhone for more information.")
                .font(.footnote)
        }
    }
}
