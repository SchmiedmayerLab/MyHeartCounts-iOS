//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import SFSafeSymbols
import SwiftUI


struct MenuIndicator: View {
    var body: some View {
        Image(systemSymbol: .chevronUpChevronDown)
            .imageScale(.small)
            .foregroundStyle(.gray.secondary)
            .accessibilityHidden(true)
    }
}
