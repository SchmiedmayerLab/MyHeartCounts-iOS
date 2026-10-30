//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Grove
import GroveHealthKit
import GroveOnboarding
import GroveViews
import SwiftUI


struct DemographicsStep: View {
    @Environment(ManagedNavigationStack.Path.self)
    private var path
    @State private var isComplete = false
    
    var body: some View {
        DemographicsForm(isComplete: $isComplete) {
            OnboardingActionsView("Continue") {
                path.nextStep()
            }
            .disabled(!isComplete)
            .listRowInsets(.zero)
        }
    }
}


#Preview {
    ManagedNavigationStack {
        DemographicsStep()
    }
    .previewWith(standard: MyHeartCountsStandard()) {
        HealthKit()
        MyHeartCounts.previewModels
    }
}
