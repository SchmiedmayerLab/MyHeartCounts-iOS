//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import SFSafeSymbols
import SwiftUI


struct TitleAndSymbolNavigationLinkLabel: View {
    private let symbol: SFSymbol
    private let title: Text
    
    var body: some View {
        Label {
            title
        } icon: {
            Image(systemSymbol: symbol)
                .foregroundStyle(.textLabel)
                .accessibilityHidden(true)
        }
    }
    
    // periphery:ignore - API
    nonisolated fileprivate init(symbol: SFSymbol, title: LocalizedStringResource) {
        self.symbol = symbol
        self.title = Text(title)
    }
    
    nonisolated fileprivate init(symbol: SFSymbol, title: some StringProtocol) {
        self.symbol = symbol
        self.title = Text(title)
    }
}


extension NavigationLink {
    // periphery:ignore - API
    init(
        symbol: SFSymbol,
        _ title: LocalizedStringResource,
        @ViewBuilder destination: () -> Destination
    ) where Destination: View, Label == TitleAndSymbolNavigationLinkLabel {
        self.init {
            destination()
        } label: {
            TitleAndSymbolNavigationLinkLabel(symbol: symbol, title: title)
        }
    }
    
    init(
        symbol: SFSymbol,
        _ title: some StringProtocol,
        @ViewBuilder destination: () -> Destination
    ) where Destination: View, Label == TitleAndSymbolNavigationLinkLabel {
        self.init {
            destination()
        } label: {
            TitleAndSymbolNavigationLinkLabel(symbol: symbol, title: title)
        }
    }
}
