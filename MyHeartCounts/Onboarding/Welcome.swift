//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Grove
import GroveOnboarding
import GroveViews
import SFSafeSymbols
import SwiftUI


struct Welcome: View {
    @Environment(ManagedNavigationStack.Path.self)
    private var onboardingPath
    
    var body: some View {
        OnboardingPage(title: "My Heart Counts", description: "WELCOME_SUBTITLE") {
            onboardingInformationView
        } footer: {
            OnboardingActionsView("Continue") {
                onboardingPath.nextStep()
            }
        }
    }
    
    private var onboardingInformationView: some View {
        Grid(horizontalSpacing: 16, verticalSpacing: 16) {
            OnboardingIconGridRow(
                icon: .appBadge,
                text: "WELCOME_AREA1_DESCRIPTION"
            )
            OnboardingIconGridRow(
                icon: .wandAndSparklesInverse,
                text: "WELCOME_AREA2_DESCRIPTION"
            )
            OnboardingIconGridRow(
                icon: .watchfaceApplewatchCase,
                text: "WELCOME_AREA3_DESCRIPTION"
            )
        }
        .padding(.leading)
    }
}


#Preview {
    ManagedNavigationStack {
        Welcome()
    }
}
