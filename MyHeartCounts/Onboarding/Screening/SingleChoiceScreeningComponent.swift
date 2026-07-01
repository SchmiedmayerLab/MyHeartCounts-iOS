//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

// swiftlint:disable discouraged_optional_boolean

import Foundation
import SFSafeSymbols
import SwiftUI


struct SingleChoiceScreeningComponentImpl<Option: Hashable>: View {
    enum BoolStyle {
        case list
        case toggle
    }
    
    private let question: LocalizedStringResource
    private let explanation: LocalizedStringResource?
    private let options: [Option]
    @Binding private var selection: Option?
    private let optionTitle: (Option) -> LocalizedStringResource
    private let boolStyle: BoolStyle?
    
    var body: some View {
        if let binding = _selection as? Binding<Bool?>, let boolStyle {
            switch boolStyle {
            case .list:
                listBody
            case .toggle:
                Toggle(isOn: binding.withDefault(false)) {
                    label
                }
            }
        } else {
            listBody
        }
    }
    
    private var label: some View {
        VStack(alignment: .leading) {
            Text(question)
                .fontWeight(.medium)
            if let explanation {
                Text(explanation)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
    
    @ViewBuilder private var listBody: some View {
        label
        ForEach(options, id: \.self) { option in
            makeRow(for: option)
        }
    }
    
    init(
        _ question: LocalizedStringResource,
        explanation: LocalizedStringResource? = nil,
        options: [Option],
        selection: Binding<Option?>,
        optionTitle: @escaping (Option) -> LocalizedStringResource
    ) {
        self.question = question
        self.explanation = explanation
        self.options = options
        self._selection = selection
        self.optionTitle = optionTitle
        self.boolStyle = nil
    }
    
    init(
        _ question: LocalizedStringResource,
        explanation: LocalizedStringResource? = nil,
        selection: Binding<Bool?>,
        style: BoolStyle
    ) where Option == Bool {
        self.question = question
        self.explanation = explanation
        self.options = [true, false]
        self._selection = selection
        self.optionTitle = { $0 ? "Yes" : "No" }
        self.boolStyle = style
    }
    
    
    private func makeRow(for option: Option) -> some View {
        Button {
            if selection == option {
                // deselect
                selection = nil
            } else {
                // select
                selection = option
            }
        } label: {
            HStack {
                Text(optionTitle(option))
                    .foregroundStyle(.textLabel)
                if selection == option {
                    Spacer()
                    Image(systemSymbol: .checkmark)
                        .foregroundStyle(.accent)
                        .fontWeight(.medium)
                        .accessibilityLabel("Selection Checkmark")
                }
            }
            .contentShape(Rectangle())
        }
    }
}
