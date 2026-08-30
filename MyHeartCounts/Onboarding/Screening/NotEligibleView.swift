//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import GroveViews
import SFSafeSymbols
import SwiftUI


struct NotEligibleView: View {
    var body: some View {
        OnboardingPage(
            title: "INELIGIBLE_TITLE",
            description: "INELIGIBLE_SUBTITLE"
        ) {
            Link2(MyHeartCounts.website(.homepage)) {
                HStack {
                    Text("INELIGIBLE_LEARN_MORE")
                    Spacer()
                    Image(systemSymbol: .arrowUpRight)
                        .accessibilityHidden(true)
                }
                .buttonStyleGlassProminent()
            }
        }
    }
}


#Preview {
    NotEligibleView()
}
