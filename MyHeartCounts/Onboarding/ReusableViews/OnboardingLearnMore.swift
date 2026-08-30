//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import GroveViews
import SwiftUI


struct OnboardingLearnMore: View {
    let title: LocalizedStringResource
    let learnMoreText: LocalizedStringResource
    
    
    var body: some View {
        NavigationStack {
            ScrollView {
                Text(learnMoreText)
                    .padding()
            }
            .scrollBounceBehavior(.basedOnSize)
            .navigationTitle(String(localized: title))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    DismissButton()
                }
            }
        }
    }
}


#Preview {
    ManagedNavigationStack {
        OnboardingLearnMore(
            title: "ONBOARDING_DISCLAIMER_1_TITLE",
            learnMoreText: "ONBOARDING_DISCLAIMER_1_LEARN_MORE_TEXT"
        )
    }
}
