//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import SFSafeSymbols
import SpeziViews
import SwiftUI

/// A view which lets users select an item from a list of options.
/// Intended to be used as a sheet.
struct ListSelectionSheet<Items: RandomAccessCollection>: View where Items.Element: Hashable {
    typealias Item = Items.Element
    
    @Environment(\.dismiss)
    private var dismiss
    
    private let title: LocalizedStringResource
    private let items: Items
    @State private var displayedItems: [Item]
    @Binding private var selection: Item?
    private let makeTitle: (Item) -> String
    private let dismissAfterSelection: Bool
    @State private var searchTerm = ""
    
    var body: some View {
        NavigationStack { // swiftlint:disable:this closure_body_length
            Form {
                ForEach(displayedItems, id: \.self) { item in
                    Button {
                        if selection == item {
                            // if we're re-selecting the currently selected item, we clear the selection
                            // maybe add an option for enabling/disabling this behaviour?
                            selection = nil
                        } else {
                            selection = item
                            if dismissAfterSelection {
                                dismiss()
                            }
                        }
                    } label: {
                        HStack {
                            Text(makeTitle(item))
                                .foregroundStyle(.textLabel)
                            if item == selection {
                                Spacer()
                                Image(systemSymbol: .checkmark)
                                    .foregroundStyle(.blue)
                                    .accessibilityLabel("Selection Checkmark")
                            }
                        }
                        .contentShape(Rectangle())
                    }
                }
            }
            .navigationTitle(LocalizedStringKey(title.key))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // ISSUE why doesn't this look good in light mode? (can't see the circle surrounding the cross.)
                    // how does Apple do this, in eg the Maps app?
                    DismissButton()
                }
            }
            .searchable(text: $searchTerm, placement: searchFieldPlacement)
            .onChange(of: searchTerm) { _, newValue in
                guard !newValue.isEmpty else {
                    displayedItems = Array(items)
                    return
                }
                displayedItems = items.filter { item in
                    // QUESTION does this do stuff like allowing eg an 'e' to compare equal to an 'é'?
                    makeTitle(item).localizedCaseInsensitiveContains(newValue)
                }
            }
        }
    }
    
    private var searchFieldPlacement: SearchFieldPlacement {
        if #available(iOS 26, *) {
            .automatic
        } else {
            .navigationBarDrawer(displayMode: .always)
        }
    }
    
    
    init(
        _ title: LocalizedStringResource,
        items: Items,
        selection: Binding<Item?>,
        dismissAfterSelection: Bool = true,
        makeTitle: @escaping (Item) -> String
    ) {
        self.title = title
        self.items = items
        self._selection = selection
        self.dismissAfterSelection = dismissAfterSelection
        self._displayedItems = .init(initialValue: Array(items))
        self.makeTitle = makeTitle
    }
}
