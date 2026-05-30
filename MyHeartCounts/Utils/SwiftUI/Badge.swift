//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import SwiftUI


struct Badge<Label: View>: View {
    private let label: Label
    
    var body: some View {
        label
            .font(.caption.weight(.medium))
            .foregroundStyle(.tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 4)
            .background(.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
    }
    
    init(@ViewBuilder label: @MainActor () -> Label) {
        self.label = label()
    }
    
    init(_ title: LocalizedStringResource) where Label == Text {
        self.init {
            Text(title)
        }
    }
    
    init(_ title: LocalizedStringKey, bundle: Bundle) where Label == Text {
        self.init {
            Text(title, bundle: bundle)
        }
    }
}

