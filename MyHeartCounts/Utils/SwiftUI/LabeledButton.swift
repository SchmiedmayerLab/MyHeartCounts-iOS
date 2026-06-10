//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import SFSafeSymbols
import SpeziViews
import SwiftUI


struct LabeledButton: View {
    private let symbol: SFSymbol
    private let title: LocalizedStringResource
    private let subtitle: LocalizedStringResource
    private let action: @MainActor @Sendable () async throws -> Void
    @Binding private var state: ViewState
    
    var body: some View {
        AsyncButton(state: $state, action: action) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemSymbol: symbol)
                    .accessibilityHidden(true)
                VStack(alignment: .listRowSeparatorLeading) {
                    Text(title)
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.textLabel.secondary)
                }
            }
        }
    }
    
    init(
        symbol: SFSymbol,
        title: LocalizedStringResource,
        subtitle: LocalizedStringResource,
        state: Binding<ViewState>,
        action: @escaping @MainActor @Sendable () async throws -> Void
    ) {
        self.symbol = symbol
        self.title = title
        self.subtitle = subtitle
        self._state = state
        self.action = action
    }
}
