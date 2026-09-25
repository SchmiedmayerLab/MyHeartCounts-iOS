//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Grove
import SwiftUI


@main
struct MHCWatchApp: App {
    @ApplicationDelegateAdaptor(MHCWatchAppDelegate.self)
    private var appDelegate
    
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                ContentView()
            }
            .grove(appDelegate)
        }
    }
}
