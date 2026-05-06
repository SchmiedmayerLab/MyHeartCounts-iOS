//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

// swiftlint:disable file_types_order attributes file_length

import Foundation
import MyHeartCountsShared
import SpeziHealthKit
import SwiftUI


// MARK: DemographicsLayout

protocol DemographicsComponent {
    associatedtype View: SwiftUI.View
    
    @MainActor
    @ViewBuilder
    var view: View { get }
    
    @MainActor
    func isComplete(in data: DemographicsData) -> Bool
}


@MainActor
@DemographicsLayoutBuilder
func demographicsLayout(for region: Locale.Region) -> some DemographicsComponent { // swiftlint:disable:this function_body_length
    Section {
        LeafComponent(\.dateOfBirth) { binding, isEmpty in
            let binding = binding.withDefault(.now)
            VStack {
                DatePicker(
                    "Date of Birth",
                    selection: Binding<Date> {
                        Calendar.current.makeNoon(binding.wrappedValue)
                    } set: { newValue in
                        binding.wrappedValue = Calendar.current.makeNoon(newValue)
                    },
                    displayedComponents: .date
                )
                .accessibilityLabel("Date of Birth")
                .accessibilityValue(binding.wrappedValue.formatted(.iso8601.year().month().day()))
                if isEmpty {
                    HStack {
                        Spacer()
                        Text("Missing Response")
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .padding(.trailing, 5)
                    }
                }
            }
        }
        LeafComponent(\.genderIdentity) { binding, _ in
            DemographicsPicker("Gender Identity", selection: binding, optionTitle: \.displayTitle)
        }
        LeafComponent(\.sexAtBirth) { binding, _ in
            DemographicsPicker("Biological Sex at Birth", selection: binding, optionTitle: \.displayTitle)
        }
        LeafComponent(\.bloodType) { binding, _ in
            DemographicsPicker("Blood Type", selection: binding, allOptions: HKBloodType.allKnownValues, optionTitle: \.displayTitle)
        }
    }
    Section {
        BodyMeasurementRow(descriptor: .height)
        BodyMeasurementRow(descriptor: .weight)
    }
    Section {
        LeafComponent(\.raceEthnicity) { binding, isEmpty in
            let binding = binding.withDefault([])
            NavigationLink {
                RaceEthnicityPicker(selection: binding)
            } label: {
                HStack {
                    Text("Race / Ethnicity")
                    Spacer()
                    Text(binding.wrappedValue.localizedDisplayTitle)
                        .foregroundStyle(isEmpty ? .red : .secondary)
                }
            }
        }
        if region == .unitedStates {
            LeafComponent(\.latinoStatus) { binding, _ in
                makeSimpleValuePickerRow("Are you Hispanic/Latino?", binding: binding.withDefault(.notSet))
            }
        }
    }
    Section {
        LeafComponent(\.comorbidities) { binding, _ in
            NavigationLink {
                ComorbiditiesPicker(selection: binding.withDefault(Comorbidities()))
                    .onAppear {
                        if binding.wrappedValue == nil {
                            // If the value initially is nil, we set it to an empty selection when the picker is presented
                            // (ie, when the user taps the "Comorbidities" row in the form),
                            // this way we treat the user having looked at the list but not having selected anything
                            // as the user telling us they don't have any comorbidities
                            binding.wrappedValue = Comorbidities()
                        }
                    }
            } label: {
                if let comorbidities = binding.wrappedValue {
                    NavigationLinkLabel("Comorbidities", isEmpty: false, value: "\(comorbidities.count) selected")
                } else {
                    NavigationLinkLabel("Comorbidities", isEmpty: true, value: "Not Set")
                }
            }
        }
    }
    Section { // swiftlint:disable:this closure_body_length
        switch region {
        case .unitedStates:
            LeafComponent(\.usRegion) { binding, isEmpty in
                NavigationLink {
                    USRegionPicker(selection: binding)
                } label: {
                    NavigationLinkLabel(
                        "US State / Territory",
                        isEmpty: isEmpty,
                        value: (binding.wrappedValue?.abbreviation).map { "\($0)" } ?? "No Selection"
                    )
                }
            }
            LeafComponent(\.usEducationLevel) { binding, _ in
                makeSimpleValuePickerRow("Education Level", binding: binding.withDefault(.notSet))
            }
            LeafComponent(\.usHouseholdIncome) { binding, _ in
                makeSimpleValuePickerRow("Total Household Income", binding: binding.withDefault(.notSet))
            }
        case .unitedKingdom:
            LeafComponent(\.ukRegion) { binding, isEmpty in
                NavigationLink {
                    UKRegionPicker(selection: binding)
                } label: {
                    NavigationLinkLabel(
                        "UK Region",
                        isEmpty: isEmpty,
                        value: binding.wrappedValue?.displayTitle ?? "Not Set"
                    )
                }
            }
            LeafComponent(\.ukEducationLevel) { binding, _ in
                makeSimpleValuePickerRow("Education Level", binding: binding.withDefault(.notSet))
            }
            LeafComponent(\.ukHouseholdIncome) { binding, _ in
                makeSimpleValuePickerRow("Total Household Income", binding: binding.withDefault(.notSet))
            }
        default:
            _EmptyComponent()
        }
    }
    if region == .unitedKingdom {
        LeafComponent(\.nhsNumber) { binding, _ in
            let binding = binding.withDefault(NHSNumber(unchecked: ""))
            SwiftUI.Section {
                NHSNumberTextField(value: binding)
            } header: {
                Text("NHS Number")
            } footer: {
                Link2("Find your NHS Number", "https://www.nhs.uk/nhs-services/online-services/find-nhs-number/")
                    .font(.footnote)
                    .tint(.blue)
            }
        }
    }
    Section {
        LeafComponent(\.stageOfChange) { binding, isEmpty in
            NavigationLink {
                StageOfChangePicker(selection: binding)
            } label: {
                NavigationLinkLabel(
                    "Stage of Change",
                    isEmpty: isEmpty,
                    value: isEmpty ? "No Selection" : "\(binding.withDefault(.notSet).id.uppercased())"
                )
            }
        }
    }
}


// MARK: Supporting Views

@MainActor
@ViewBuilder
private func makeSimpleValuePickerRow(_ title: LocalizedStringResource, binding: Binding<some DemographicsSelectableSimpleValue>) -> some View {
    NavigationLink {
        DemographicsSingleSelectionPicker(selection: binding)
            .navigationTitle(title)
    } label: {
        NavigationLinkLabel(
            title,
            isEmpty: binding.wrappedValue == .notSet,
            value: binding.wrappedValue.displayTitle
        )
    }
}


/// A label for use in a `NavigationLink`; automatically adjusts its value's text color based on the presence/absence of a value.
///
/// Intended for use in the ``DemographicsForm``, to highlight missing answers.
private struct NavigationLinkLabel: View {
    private let title: LocalizedStringResource
    private let isEmpty: Bool
    private let value: LocalizedStringResource
    
    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(isEmpty ? .red : .secondary)
        }
    }
    
    init(_ title: LocalizedStringResource, isEmpty: Bool, value: LocalizedStringResource) {
        self.title = title
        self.isEmpty = isEmpty
        self.value = value
    }
}


/// A Form row view for a quantity-based body measurement, e.g. height or weight.
private struct BodyMeasurementRow: DemographicsComponent {
    @MainActor
    struct BodyMeasurementDescriptor {
        static var height: Self { Self(sampleType: .healthKit(.height), fieldKeyPath: \.height) }
        static var weight: Self { Self(sampleType: .healthKit(.bodyMass), fieldKeyPath: \.weight) }
        
        nonisolated let sampleType: MHCQuantitySampleType
        let fieldKeyPath: ReferenceWritableKeyPath<DemographicsData, DemographicsData.Field<HKQuantity>>
    }
    
    struct View: SwiftUI.View {
        @Environment(\.colorScheme) private var colorScheme
        @Environment(DemographicsData.self) private var data
        
        let descriptor: BodyMeasurementDescriptor
        @State var isShowingDataEntry = false
        
        var body: some SwiftUI.View {
            let sampleType = descriptor.sampleType
            Button {
                isShowingDataEntry = true
            } label: {
                HStack {
                    Text(sampleType.displayTitle)
                        .foregroundStyle(colorScheme.textLabelForegroundStyle)
                    Spacer()
                    let sample = data[descriptor.fieldKeyPath].flatMap { quantity in
                        QuantitySample(id: UUID(), sampleType: descriptor.sampleType, quantity: quantity, startDate: .now, endDate: .now)
                    }
                    Text(sample?.valueAndUnitDescription(for: sampleType.displayUnit) ?? "—")
                        .foregroundStyle(sample == nil ? .red : .secondary)
                }
                .contentShape(Rectangle())
            }
            .sheet(isPresented: $isShowingDataEntry) {
                NavigationStack {
                    SaveQuantitySampleView(sampleType: sampleType) { sample in
                        data[descriptor.fieldKeyPath] = HKQuantity(unit: sample.unit, doubleValue: sample.value)
                    }
                }
            }
        }
    }
    
    let descriptor: BodyMeasurementDescriptor
    
    var view: View {
        View(descriptor: descriptor)
    }
    
    func isComplete(in data: DemographicsData) -> Bool {
        !data.isEmpty(descriptor.fieldKeyPath)
    }
}


/// A `Menu`-styled `Picker` intended for use in the demographics form.
private struct DemographicsPicker<Value: Hashable>: View {
    private let title: LocalizedStringResource
    @Binding private var selection: Value?
    private let allOptions: [Value]
    private let optionTitle: (Value) -> LocalizedStringResource
    
    var body: some View {
        Picker(title, selection: $selection) {
            Text("—")
                .tag(Value?.none)
                .selectionDisabled()
            Divider()
            ForEach(allOptions, id: \.self) { option in
                Text(optionTitle(option))
                    .tag(option)
            }
        }
        .pickerStyle(.menu)
        .tint(selection == nil ? .red : .secondary)
    }
    
    init(
        _ title: LocalizedStringResource,
        selection: Binding<Value?>,
        allOptions: [Value],
        optionTitle: @escaping (Value) -> LocalizedStringResource
    ) {
        self.title = title
        self._selection = selection
        self.allOptions = allOptions
        self.optionTitle = optionTitle
    }
    
    init(
        _ title: LocalizedStringResource,
        selection: Binding<Value?>,
        optionTitle: @escaping (Value) -> LocalizedStringResource
    ) where Value: CaseIterable {
        self.init(title, selection: selection, allOptions: Array(Value.allCases), optionTitle: optionTitle)
    }
}


// MARK: Base Components

/// A leaf in the demographics layout, i.e. a row in the SwiftUI Form. Displays an editable UI for a value in the demographics.
private struct LeafComponent<Value, Content: SwiftUI.View>: DemographicsComponent {
    struct View: SwiftUI.View {
        @Environment(DemographicsData.self) private var data
        
        let fieldKeyPath: ReferenceWritableKeyPath<DemographicsData, DemographicsData.Field<Value>>
        let content: @MainActor (Binding<Value?>, _ isEmpty: Bool) -> Content
        
        var body: some SwiftUI.View {
            @Bindable var data = data
            let binding = Binding<Value?> {
                data[fieldKeyPath]
            } set: {
                data[fieldKeyPath] = $0
            }
            let isEmpty = data[keyPath: fieldKeyPath].isEmpty
            content(binding, isEmpty)
        }
    }
    
    private let fieldKeyPath: ReferenceWritableKeyPath<DemographicsData, DemographicsData.Field<Value>>
    private let content: @MainActor (Binding<Value?>, _ isEmpty: Bool) -> Content
    
    
    var view: View {
        View(fieldKeyPath: fieldKeyPath, content: content)
    }
    
    init(
        _ fieldKeyPath: ReferenceWritableKeyPath<DemographicsData, DemographicsData.Field<Value>>,
        @ViewBuilder content: @escaping @MainActor (_ binding: Binding<Value?>, _ isEmpty: Bool) -> Content
    ) {
        self.fieldKeyPath = fieldKeyPath
        self.content = content
    }
    
    func isComplete(in data: DemographicsData) -> Bool {
        !data.isEmpty(fieldKeyPath)
    }
}


/// Groups one or more `DemographicsComponent`s and has an optional header and footer.
private struct Section<Content: DemographicsComponent, Header: View, Footer: View>: DemographicsComponent {
    private let content: Content
    private let header: Header
    private let footer: Footer
    
    var view: some SwiftUI.View {
        SwiftUI.Section {
            content.view
        } header: {
            header
        } footer: {
            footer
        }
    }
    
    init(
        @DemographicsLayoutBuilder content: () -> Content,
        @ViewBuilder header: () -> Header = { EmptyView() },
        @ViewBuilder footer: () -> Footer = { EmptyView() }
    ) {
        self.content = content()
        self.header = header()
        self.footer = footer()
    }
    
    func isComplete(in data: DemographicsData) -> Bool {
        content.isComplete(in: data)
    }
}


// MARK: Supporting Types

@resultBuilder
private enum DemographicsLayoutBuilder {
    static func buildOptional<C: DemographicsComponent>(_ component: C?) -> _ConditionalComponent<C, _EmptyComponent> {
        if let component {
            _ConditionalComponent(storage: .true(component))
        } else {
            _ConditionalComponent(storage: .false(_EmptyComponent()))
        }
    }
    
    static func buildEither<True: DemographicsComponent, False: DemographicsComponent>(
        first component: True
    ) -> _ConditionalComponent<True, False> {
        _ConditionalComponent(storage: .true(component))
    }
    
    static func buildEither<True: DemographicsComponent, False: DemographicsComponent>(
        second component: False
    ) -> _ConditionalComponent<True, False> {
        _ConditionalComponent(storage: .false(component))
    }
    
    // periphery:ignore - implicity called
    static func buildBlock() -> some DemographicsComponent {
        _EmptyComponent()
    }
    
    static func buildBlock(_ component: some DemographicsComponent) -> some DemographicsComponent {
        component
    }
    
    static func buildBlock<each Component: DemographicsComponent>(
        _ component: repeat each Component
    ) -> _TupleComponent<repeat each Component> {
        _TupleComponent((repeat each component))
    }
}


/// A component that does not contain any content.
private struct _EmptyComponent: DemographicsComponent {
    var view: some SwiftUI.View {
        EmptyView()
    }
    
    nonisolated init() {}
    
    func isComplete(in data: DemographicsData) -> Bool {
        true
    }
}


private struct _TupleComponent<each Component: DemographicsComponent>: DemographicsComponent {
    private let component: (repeat each Component)
    
    var view: some SwiftUI.View {
        ViewBuilder.buildBlock(repeat (each component).view)
    }
    
    init(_ component: (repeat each Component)) {
        self.component = component
    }
    
    func isComplete(in data: DemographicsData) -> Bool {
        for component in repeat each component {
            if !component.isComplete(in: data) { // swiftlint:disable:this for_where
                return false
            }
        }
        return true
    }
}


private struct _ConditionalComponent<True: DemographicsComponent, False: DemographicsComponent>: DemographicsComponent {
    enum Storage {
        case `true`(True)
        case `false`(False)
    }
    
    let storage: Storage
    
    var view: some SwiftUI.View {
        switch storage {
        case .true(let content):
            content.view
        case .false(let content):
            content.view
        }
    }
    
    func isComplete(in data: DemographicsData) -> Bool {
        switch storage {
        case .true(let content):
            content.isComplete(in: data)
        case .false(let content):
            content.isComplete(in: data)
        }
    }
}
