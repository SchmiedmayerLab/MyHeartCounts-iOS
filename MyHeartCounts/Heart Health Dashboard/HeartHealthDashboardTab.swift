//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import SFSafeSymbols
import SpeziHealthKit
import SpeziHealthKitUI
import SpeziViews
import SwiftUI


struct HeartHealthDashboardTab: RootViewTab {
    static var tabTitle: LocalizedStringResource {
        // intentionally keeping the title here as just "Heart Health"
        // (instead of "MHC Heart Health", which is what we use for the navigation title),
        // in order to make it better fit in the tab bar item...
        "Heart Health"
    }
    static var tabSymbol: SFSymbol {
        .stethoscope
    }
    
    var body: some View {
        NavigationStack {
            HeartHealthDashboard()
                .navigationTitle("MHC Heart Health")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        ParticipationStatsButton()
                    }
                    if #available(iOS 26, *) {
                        ToolbarSpacer(.fixed, placement: .topBarTrailing)
                    }
                    accountToolbarItem
                }
        }
    }
}


extension AnySampleType {
    /// The sample type's display name, for usage in My Heart Counts.
    ///
    /// - Important: Always use this property instead of `displayTitle`!
    var mhcDisplayTitle: String {
        if self == .bloodGlucose {
            String(localized: "Fasting Blood Glucose")
        } else {
            self.displayTitle
        }
    }
}
