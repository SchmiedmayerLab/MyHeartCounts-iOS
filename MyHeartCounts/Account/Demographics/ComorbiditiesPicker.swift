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


struct ComorbiditiesPicker: View {
    private typealias Comorbidity = Comorbidities.Comorbidity
    
    @Environment(\.dismiss)
    private var dismiss
    
    @Binding private var comorbidities: Comorbidities
    @State private var highlightedOption: Comorbidity?
    
    var body: some View {
        Form {
            Section {
                ForEach(Comorbidity.primaryComorbidities) { option in
                    makeRow(option)
                }
            }
            Section {
                ForEach(Comorbidity.secondaryComorbidities) { option in
                    makeRow(option)
                }
            }
            if comorbidities.isEmpty {
                // we offer a "none of these apply to me" button, but only if the user hasn't yet selected anything.
                // the reason for this is that, were they to accidentally tap the "None" button after already having
                // selected one/multiple options above, and having already entered start dates for these options,
                // all of that would be lost. (which is more problematic than for the other questions we have in the
                // demographics, since these are only boolean yes/no selections, whereas this one also has a follow-
                // up question (the start date)).
                Button("None") {
                    dismiss()
                }
            }
        }
        .navigationTitle("Select Comorbidities")
        .sheet(item: $highlightedOption) { option in
            Sheet(option: option, selection: $comorbidities[option])
        }
    }
    
    init(selection: Binding<Comorbidities>) {
        _comorbidities = selection
    }
    
    @ViewBuilder
    private func makeRow(_ option: Comorbidity) -> some View {
        Button {
            if comorbidities[option] == .notSelected {
                comorbidities[option] = .selected(startDate: DateComponents())
            }
            highlightedOption = highlightedOption == option ? nil : option
        } label: {
            HStack {
                VStack(alignment: .leading) {
                    Text(option.title)
                    if let subtitle = option.subtitle {
                        Text(subtitle)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(.textLabel)
                Spacer()
                switch comorbidities[option] {
                case .notSelected:
                    EmptyView()
                case .selected:
                    Image(systemSymbol: .checkmark)
                        .foregroundStyle(.blue)
                        .fontWeight(.medium)
                        .accessibilityLabel("Selected")
                }
            }
            .contentShape(Rectangle())
        }
    }
}


extension ComorbiditiesPicker {
    private struct Sheet: View {
        @Environment(\.dismiss)
        private var dismiss
        
        @Environment(\.locale)
        private var locale
        
        let option: Comorbidity
        @Binding var selection: Comorbidities.Status
        
        var body: some View {
            NavigationStack { // swiftlint:disable:this closure_body_length
                Form { // swiftlint:disable:this closure_body_length
                    Section {
                        Button {
                            if selection == .notSelected {
                                selection = .selected(startDate: DateComponents())
                            }
                        } label: {
                            HStack {
                                Text("I have this comorbidity")
                                Spacer()
                                // No need to have a condition here, this sheet is only presented if the user has selected yes.
                                Image(systemSymbol: .checkmark)
                                    .fontWeight(.medium)
                                    .accessibilityLabel("Selection Checkmark")
                            }
                        }
                        Button("I don't have this comorbidity") {
                            selection = .notSelected
                            dismiss()
                        }
                    }
                    Section("Date of Diagnosis") {
                        let binding = Binding<Bool> {
                            switch selection {
                            case .notSelected:
                                false
                            case .selected(let startDate):
                                startDate.year != nil
                            }
                        } set: { newValue in
                            let currentYear = locale.calendar.component(.year, from: .now)
                            if newValue {
                                switch selection {
                                case .notSelected:
                                    selection = .selected(startDate: DateComponents(year: currentYear))
                                case .selected(var startDate):
                                    startDate.year = startDate.year ?? currentYear
                                    selection = .selected(startDate: startDate)
                                }
                            } else {
                                selection = .selected(startDate: DateComponents())
                            }
                        }
                        Picker("", selection: binding) {
                            Text("Don't Know").tag(false)
                            Text("Select Date").tag(true)
                        }
                        .pickerStyle(.segmented)
                        MonthYearPicker(selection: $selection)
                    }
                }
                .navigationTitle(option.title)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            dismiss()
                        } label: {
                            Label("Done", systemSymbol: .checkmark)
                        }
                    }
                }
            }
        }
    }
}


extension ComorbiditiesPicker {
    /// A custom date picker that supports month-and-year, just-year, and empty selections.
    private struct MonthYearPicker: View {
        @Environment(\.locale)
        private var locale
        
        @Binding var selection: Comorbidities.Status
        
        private var currentYear: Int {
            locale.calendar.component(.year, from: .now)
        }
        
        var body: some View {
            HStack(spacing: 0) {
                Picker("", selection: $selection.dateComponentsValue.month) {
                    Text("—")
                        .tag(Int?.none)
                    ForEach(0..<12, id: \.self) { monthIdx in
                        Text(locale.calendar.monthSymbols[monthIdx])
                            .tag(monthIdx + 1)
                    }
                }
                .accessibilityIdentifier("MonthPicker")
                Picker("", selection: $selection.dateComponentsValue.year) {
                    Text("—")
                        .tag(Int?.none)
                    ForEach(((currentYear - 100)...currentYear).reversed(), id: \.self) { year in
                        Text(String(year))
                            .tag(year)
                    }
                }
                .accessibilityIdentifier("YearPicker")
            }
            .pickerStyle(.wheel)
        }
    }
}


extension Comorbidities.Status {
    fileprivate var dateComponentsValue: DateComponents {
        get {
            switch self {
            case .notSelected:
                DateComponents()
            case .selected(let startDate):
                startDate
            }
        }
        set {
            // NOTE: all of this needs to happen in here, rather than in an `onChange(of:)` somewhere in a view;
            // the reason being that if we eg go from a fully empty state (ie, no month and no year) to a state where only a month is selected,
            // the serialization will immediately turn that back into an empty selection (bc just a month is invalid),
            // whereas what we actually want is to set the year to the current year.
            var newValue = newValue
            let oldValue = self.dateComponentsValue
            let didChangeMonth = newValue.month != oldValue.month
            let didChangeYear = newValue.year != oldValue.year
            if didChangeYear && newValue.year == nil && oldValue.month != nil {
                newValue.month = nil
            } else if didChangeMonth && oldValue.month == nil && newValue.month != nil && newValue.year == nil {
                newValue.year = Calendar.current.component(.year, from: .now)
            }
            self = .selected(startDate: newValue)
        }
    }
}
