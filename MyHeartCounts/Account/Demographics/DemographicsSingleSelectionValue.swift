//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

// swiftlint:disable file_types_order

import Foundation
import SFSafeSymbols
import SwiftUI


protocol DemographicsSelectableSimpleValue: Identifiable, RawRepresentableAccountKey, Hashable {
    static var notSet: Self { get }
    static var preferNotToState: Self? { get }
    
    /// all options, except for ``notSet`` and ``preferNotToState``.
    static var options: [Self] { get }
    
    var displayTitle: LocalizedStringResource { get }
    var displaySubtitle: LocalizedStringResource? { get }
}


extension DemographicsSelectableSimpleValue {
    var id: RawValue {
        rawValue
    }
    
    var displaySubtitle: LocalizedStringResource? {
        nil
    }
    
    init?(rawValue: RawValue) {
        let allOptions: [Self] = Self.options + [.notSet, .preferNotToState].compactMap(\.self)
        if let option = allOptions.first(where: { $0.rawValue == rawValue }) {
            self = option
        } else {
            return nil
        }
    }
}


extension DemographicsSelectableSimpleValue {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}


struct DemographicsSingleSelectionPicker<Value: DemographicsSelectableSimpleValue, Header: View>: View {
    private let header: Header
    @Binding private var selection: Value
    
    var body: some View {
        Form {
            if !(header is EmptyView) {
                Section {
                    header
                }
            }
            Section {
                ForEach(Value.options) { option in
                    makeRow(for: option)
                }
            }
            if let preferNotToState = Value.preferNotToState {
                Section {
                    makeRow(for: preferNotToState)
                }
            }
        }
    }
    
    init(selection: Binding<Value>, @ViewBuilder header: () -> Header = { EmptyView() }) {
        self._selection = selection
        self.header = header()
    }
    
    @ViewBuilder
    private func makeRow(for option: Value) -> some View {
        Button {
            selection = option
        } label: {
            HStack {
                VStack(alignment: .leading) {
                    Text(option.displayTitle)
                    if let subtitle = option.displaySubtitle {
                        Text(subtitle)
                            .foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(.textLabel)
                Spacer()
                if option == selection {
                    Image(systemSymbol: .checkmark)
                        .fontWeight(.medium)
                        .tint(.blue)
                        .accessibilityLabel("Selection Checkmark")
                }
            }
            .contentShape(Rectangle())
        }
    }
}
