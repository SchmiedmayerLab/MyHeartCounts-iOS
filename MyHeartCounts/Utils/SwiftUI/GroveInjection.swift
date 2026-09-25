//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Grove
import SwiftUI


struct GroveInjectionModifier: ViewModifier {
    @Environment(MyHeartCountsDelegate.self)
    private var appDelegate
    
    func body(content: Content) -> some View {
        content
            .grove(appDelegate)
    }
}


extension View {
    /// Injects the default `Grove` instance into the view hierarchy.
    func injectingGrove() -> some View {
        self.modifier(GroveInjectionModifier())
    }
}
