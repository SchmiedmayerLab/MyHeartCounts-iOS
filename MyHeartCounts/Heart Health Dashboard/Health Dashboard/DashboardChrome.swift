//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

// swiftlint:disable file_types_order

import SFSafeSymbols
import SwiftUI
import class UIKit.UIColor


extension ShapeStyle where Self == Color {
    /// The fill used for tiles in a dashboard-style layout (e.g. the Heart Health Dashboard, the Participation Stats view).
    ///
    /// Resolves to white in light mode and a subtle dark gray in dark mode, ensuring the tile reads
    /// as distinct from the surrounding `dashboardBackground` in both color schemes.
    static var dashboardTile: Color {
        Color(uiColor: .secondarySystemGroupedBackground)
    }

    /// The outer background for a dashboard-style layout, behind the tiles.
    static var dashboardBackground: Color {
        Color(uiColor: .systemGroupedBackground)
    }
}


extension View {
    /// Applies the standard dashboard-tile chrome: a rounded-rect fill in ``ShapeStyle/dashboardTile``.
    ///
    /// Use this instead of `.background(.background, in: ...)` for any tile that lives on a
    /// ``ShapeStyle/dashboardBackground``-colored surface — `.background` (i.e. `systemBackground`) and
    /// `systemGroupedBackground` are visually identical in dark mode, so a tile using `.background` will
    /// disappear into the dashboard background.
    func dashboardTileBackground(cornerRadius: CGFloat = 14) -> some View {
        background(.dashboardTile, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}


/// A `Section` containing a two-column `LazyVGrid` of tile views.
///
/// Use inside a `Form` (or `List`). The contained grid renders edge-to-edge by clearing the section row's
/// insets and background; individual tiles inside the `tiles` builder are responsible for their own chrome
/// (typically via ``SwiftUICore/View/dashboardTileBackground(cornerRadius:)``).
struct TiledSection<Tiles: View>: View {
    private let title: LocalizedStringResource
    private let symbol: SFSymbol?
    private let tiles: Tiles
    
    var body: some View {
        Section {
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 12, alignment: .top),
                    GridItem(.flexible(), spacing: 12, alignment: .top)
                ],
                spacing: 12
            ) {
                tiles
            }
            .listRowInsets(.zero)
            .listRowBackground(Color.clear)
        } header: {
            if let symbol {
                Label {
                    Text(title)
                } icon: {
                    Image(systemSymbol: symbol)
                        .accessibilityHidden(true)
                }
            } else {
                Text(title)
            }
        }
    }

    init(_ title: LocalizedStringResource, symbol: SFSymbol? = nil, @ViewBuilder tiles: () -> Tiles) {
        self.title = title
        self.symbol = nil //symbol
        self.tiles = tiles()
    }
}
