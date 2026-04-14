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


struct USRegionPicker: View {
    @Environment(\.colorScheme)
    private var colorScheme
    
    @Binding var selection: USRegion?
    
    var body: some View {
        Form {
            makeSection(title: "", regions: USRegion.allStatesAndDC)
            makeSection(title: "Other Territories", regions: USRegion.otherTerritories)
            makeSection(title: "", regions: [.notSet])
        }
        .navigationTitle("Select your State or Territory")
        .navigationBarTitleDisplayMode(.inline) // otherwise it won't fit
    }
    
    @ViewBuilder
    private func makeSection(title: LocalizedStringKey, regions: [USRegion]) -> some View {
        Section(title) {
            ForEach(regions, id: \.self) { region in
                makeRow(region)
            }
        }
    }
    
    @ViewBuilder
    private func makeRow(_ region: USRegion) -> some View {
        Button {
            selection = region == selection ? nil : region
        } label: {
            HStack {
                Text(region.name)
                Spacer()
                if region == selection {
                    Image(systemSymbol: .checkmark)
                        .fontWeight(.medium)
                        .accessibilityLabel("Selection Checkmark")
                        .foregroundStyle(.blue)
                }
                Text(region.abbreviation)
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(colorScheme.textLabelForegroundStyle)
        }
    }
}
