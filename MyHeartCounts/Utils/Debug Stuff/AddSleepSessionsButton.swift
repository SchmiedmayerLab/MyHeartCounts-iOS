//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

// swiftlint:disable attributes

import Foundation
import GroveFoundation
import GroveHealthKit
import GroveViews
import SwiftUI


struct AddSleepSessionsButton: View {
    @Environment(DemoSetup.self) private var demoSetup
    
    @Binding var viewState: ViewState
    
    var body: some View {
        AsyncButton("Add Sleep Sessions" as String, state: $viewState) {
            try await demoSetup.addDemoSleepSamples()
        }
    }
}
