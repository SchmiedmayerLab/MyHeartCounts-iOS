//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import MHCStudyDefinition
import SFSafeSymbols
import SwiftUI


struct StageOfChangePicker: View {
    enum SectionsLayout {
        case single
        case separate
    }
    
    let studyVariant: StudyVariant
    @Binding var selection: StageOfChangeOption?
    
    var body: some View {
        Form {
            Section {
                Text(
                    "Please select the clause that most closely matches what you do.",
                    comment: "adapted from the instructions at https://pmc.ncbi.nlm.nih.gov/articles/PMC5367771/"
                )
            }
            content(using: .separate)
        }
        .navigationTitle(Text(studyVariant.localized(stanford: "Stage of Change", imperial: "Physical Activity Habits")))
    }
    
    @ViewBuilder
    private func content(using layout: SectionsLayout) -> some View {
        switch layout {
        case .single:
            Section {
                ForEach(StageOfChangeOption.allOptions) { option in
                    makeRow(for: option)
                }
            }
        case .separate:
            ForEach(StageOfChangeOption.allOptions) { option in
                Section {
                    makeRow(for: option)
                }
            }
        }
    }
    
    @ViewBuilder
    private func makeRow(for option: StageOfChangeOption) -> some View {
        Button {
            selection = option
        } label: {
            VStack(alignment: .leading) {
                HStack {
                    Text(option.label(for: studyVariant))
                        .font(.headline)
                        .foregroundStyle(.textLabel)
                    Spacer()
                    if option == selection {
                        Image(systemSymbol: .checkmark)
                            .accessibilityLabel("Is selected")
                    }
                }
                .frame(minHeight: 30)
                Text(option.text)
                    .foregroundStyle(.textLabel.secondary)
            }
            .contentShape(Rectangle())
        }
        .accessibilityIdentifier("StageOfChangeButton:\(option.id)")
    }
}
