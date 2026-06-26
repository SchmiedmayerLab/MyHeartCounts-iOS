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


struct RaceEthnicityPicker: View {
    @Binding var selection: RaceEthnicity
    
    var body: some View {
        Form {
            makeSection(for: RaceEthnicity.allOptions.filter { $0 != .preferNotToState }, footer: "RACE_SELECTOR_LIST_FOOTER")
            makeSection(for: CollectionOfOne(.preferNotToState))
        }
        .navigationTitle("Race / Ethnicity")
        .navigationBarTitleDisplayMode(.inline)
    }
    
    private func makeSection(for options: some RandomAccessCollection<RaceEthnicity>, footer: LocalizedStringResource? = nil) -> some View {
        Section {
            ForEach(options, id: \.self) { option in
                makeRow(for: option)
            }
        } footer: {
            if let footer {
                Text(footer)
            }
        }
    }
    
    private func makeRow(for option: RaceEthnicity) -> some View {
        Button {
            selection.update { selection in
                if option == .preferNotToState {
                    selection = option
                } else {
                    selection.toggleMembership(of: option)
                    selection.remove(.preferNotToState)
                }
            }
        } label: {
            HStack {
                Text(option.localizedDisplayTitle)
                    .foregroundStyle(.textLabel)
                Spacer()
                if selection.contains(option) {
                    Image(systemSymbol: .checkmark)
                        .fontWeight(.medium)
                        .accessibilityLabel("Selection Checkmark")
                }
            }
        }
    }
}


extension OptionSet {
    mutating func update(_ transform: (inout Self) -> Void) {
        transform(&self)
    }
}

extension SetAlgebra {
    /// Inserts or removes a member, depending on whether it currently is present in the set.
    mutating func toggleMembership(of member: Element) {
        if contains(member) {
            remove(member)
        } else {
            insert(member)
        }
    }
}
