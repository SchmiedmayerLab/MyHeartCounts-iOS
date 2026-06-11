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

/// A component within a demographics layout.
///
/// A _demographics layout_ is a tree-like structure representing the a demographics form the user is asked to fill out.
///
/// There are two kinds of components:
/// 1. Intermediate Components, which are used to structure the layout into groups and sections.
/// 2. Leaf Components, which represent actual data entry fields the user is asked to fill out.
///
/// Since the list of enabled demgraphics fields, and within a single field the question of whether it should be required or optional,
/// are non-static and depend on factors such as the user's specific enrollment region and whether the user has opted in to the trial,
/// the demographics layout as a whole is parametrized over these conditions.
protocol DemographicsComponent {
    associatedtype View: SwiftUI.View
    
    /// The component's SwiftUI representation.
    @MainActor
    @ViewBuilder
    var view: View { get }
    
    @MainActor
    func completionState(in data: DemographicsData) -> DemographicsComponentCompletionState
}


extension DemographicsComponent {
    /// Checks whether the onboarding data represented by the component is currently complete, i.e., non-empty, taking into account the field's required/optional state.
    ///
    /// For intermediate components representing multiple fields, this function checks whether all of the individual fields within the component are complete.
    @MainActor
    func isComplete(in data: DemographicsData) -> Bool {
        switch completionState(in: data) {
        case .completed:
            true
        case .incomplete(let isRequired):
            !isRequired
        }
    }
}


enum DemographicsComponentCompletionState: Hashable {
    /// The component has been completed (i.e., the user has entered a non-empty value)
    case completed
    /// The component is incomplete.
    case incomplete(isRequired: Bool)
    
    var isIncomplete: Bool {
        switch self {
        case .incomplete:
            true
        case .completed:
            false
        }
    }
    
    fileprivate var suggestedForegroundColor: Color {
        switch self {
        case .completed:
            .secondary
        case .incomplete(let isRequired):
            isRequired ? .red : .orange
        }
    }
}


/// Creates a ``DemographicsComponent`` representing the demographics form as a whole.
///
/// - parameter region: the firebase region the user is enrolled with.
/// - parameter didOptInToTrial: whether the user opted in to participate in the trial.
@MainActor
@DemographicsLayoutBuilder
func demographicsLayout( // swiftlint:disable:this function_body_length
    region: Locale.Region,
    didOptInToTrial: Bool
) -> some DemographicsComponent {
    Section { // swiftlint:disable:this closure_body_length
        LeafComponent(\.dateOfBirth) { binding, completionState in
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
                switch completionState {
                case .completed:
                    EmptyView()
                case .incomplete:
                    HStack {
                        Spacer()
                        Text("Missing Response")
                            .font(.footnote)
                            .foregroundStyle(completionState.suggestedForegroundColor)
                            .padding(.trailing, 5)
                    }
                }
            }
        }
        LeafComponent(\.genderIdentity) { binding, _ in
            DemographicsPicker("Gender Identity", selection: binding, optionTitle: \.displayTitle)
        }
        LeafComponent(\.sexAtBirth, isRequired: false) { binding, _ in
            DemographicsPicker("Biological Sex at Birth", selection: binding, optionTitle: \.displayTitle)
        }
        LeafComponent(\.bloodType, isRequired: false) { binding, _ in
            DemographicsPicker("Blood Type", selection: binding, allOptions: HKBloodType.allKnownValues, optionTitle: \.displayTitle)
        }
    }
    Section {
        BodyMeasurementRow(descriptor: .height)
        BodyMeasurementRow(descriptor: .weight)
    }
    Section {
        LeafComponent(\.raceEthnicity) { binding, completionState in
            let binding = binding.withDefault([])
            NavigationLink {
                RaceEthnicityPicker(selection: binding)
            } label: {
                HStack {
                    Text("Race / Ethnicity")
                    Spacer()
                    Text(binding.wrappedValue.localizedDisplayTitle)
                        .foregroundStyle(completionState.suggestedForegroundColor)
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
        LeafComponent(\.comorbidities, isRequired: didOptInToTrial) { binding, _ in
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
            LeafComponent(\.usRegion, isRequired: false) { binding, completionState in
                NavigationLink {
                    USRegionPicker(selection: binding)
                } label: {
                    NavigationLinkLabel(
                        "US State / Territory",
                        completionState: completionState,
                        value: (binding.wrappedValue?.abbreviation).map { "\($0)" } ?? "No Selection"
                    )
                }
            }
            LeafComponent(\.usEducationLevel, isRequired: didOptInToTrial) { binding, _ in
                makeSimpleValuePickerRow("Education Level", binding: binding.withDefault(.notSet))
            }
            LeafComponent(\.usHouseholdIncome, isRequired: false) { binding, _ in
                makeSimpleValuePickerRow("Total Household Income", binding: binding.withDefault(.notSet))
            }
        case .unitedKingdom:
            LeafComponent(\.ukRegion, isRequired: false) { binding, completionState in
                NavigationLink {
                    UKRegionPicker(selection: binding)
                } label: {
                    NavigationLinkLabel(
                        "UK Region",
                        completionState: completionState,
                        value: binding.wrappedValue?.displayTitle ?? "Not Set"
                    )
                }
            }
            // UK postcode will be asked here
            LeafComponent(\.ukEducationLevel, isRequired: didOptInToTrial) { binding, _ in
                makeSimpleValuePickerRow("Education Level", binding: binding.withDefault(.notSet))
            }
            LeafComponent(\.ukHouseholdIncome, isRequired: false) { binding, _ in
                makeSimpleValuePickerRow("Total Household Income", binding: binding.withDefault(.notSet))
            }
        default:
            _EmptyComponent()
        }
    }
    if region == .unitedKingdom {
        LeafComponent(\.nhsNumber, isRequired: false) { binding, _ in
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
        LeafComponent(\.stageOfChange, isRequired: didOptInToTrial) { binding, completionState in
            NavigationLink {
                StageOfChangePicker(selection: binding)
            } label: {
                NavigationLinkLabel(
                    "Stage of Change",
                    completionState: completionState,
                    value: completionState.isIncomplete ? "No Selection" : "\(binding.withDefault(.notSet).id.uppercased())"
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
    private let value: LocalizedStringResource
    private let valueForegroundColor: Color
    
    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(valueForegroundColor)
        }
    }
    
    init(_ title: LocalizedStringResource, isEmpty: Bool, value: LocalizedStringResource) {
        self.title = title
        self.value = value
        self.valueForegroundColor = isEmpty ? .red : .secondary
    }
    
    init(_ title: LocalizedStringResource, completionState: DemographicsComponentCompletionState, value: LocalizedStringResource) {
        self.title = title
        self.value = value
        self.valueForegroundColor = completionState.suggestedForegroundColor
    }
}


/// A Form row view for a quantity-based body measurement, e.g. height or weight.
private struct BodyMeasurementRow: DemographicsComponent {
    @MainActor
    struct BodyMeasurementDescriptor: Equatable {
        static var height: Self { Self(sampleType: .healthKit(.height), fieldKeyPath: \.height) }
        static var weight: Self { Self(sampleType: .healthKit(.bodyMass), fieldKeyPath: \.weight) }
        
        nonisolated let sampleType: MHCQuantitySampleType
        let fieldKeyPath: ReferenceWritableKeyPath<DemographicsData, DemographicsData.Field<HKQuantity>>
    }
    
    struct View: SwiftUI.View {
        @Environment(DemographicsData.self) private var data
        
        let descriptor: BodyMeasurementDescriptor
        let completionState: (DemographicsData) -> DemographicsComponentCompletionState
        @State private var isShowingDataEntry = false
        
        var body: some SwiftUI.View {
            let sampleType = descriptor.sampleType
            Button {
                isShowingDataEntry = true
            } label: {
                HStack {
                    Text(sampleType.displayTitle)
                        .foregroundStyle(.textLabel)
                    Spacer()
                    let sample = data[descriptor.fieldKeyPath].map { quantity in
                        QuantitySample(id: UUID(), sampleType: descriptor.sampleType, quantity: quantity, startDate: .now, endDate: .now)
                    }
                    Text(sample?.valueAndUnitDescription(for: sampleType.displayUnit) ?? "—")
                        .foregroundStyle(completionState(data).suggestedForegroundColor)
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
    
    private let descriptor: BodyMeasurementDescriptor
    private let isRequired: Bool
    
    var view: View {
        View(descriptor: descriptor) {
            completionState(in: $0)
        }
    }
    
    init(descriptor: BodyMeasurementDescriptor, isRequired: Bool = true) {
        self.descriptor = descriptor
        self.isRequired = isRequired
    }
    
    func completionState(in data: DemographicsData) -> DemographicsComponentCompletionState {
        if data.isEmpty(descriptor.fieldKeyPath) {
            .incomplete(isRequired: isRequired)
        } else {
            .completed
        }
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
        let content: @MainActor (Binding<Value?>, _ state: DemographicsComponentCompletionState) -> Content
        let completionState: (DemographicsData) -> DemographicsComponentCompletionState
        
        var body: some SwiftUI.View {
            @Bindable var data = data
            content($data[fieldKeyPath], completionState(data))
        }
    }
    
    private let fieldKeyPath: ReferenceWritableKeyPath<DemographicsData, DemographicsData.Field<Value>>
    private let isRequired: Bool
    private let content: @MainActor (Binding<Value?>, _ state: DemographicsComponentCompletionState) -> Content
    
    
    var view: View {
        View(fieldKeyPath: fieldKeyPath, content: content) {
            completionState(in: $0)
        }
    }
    
    init(
        _ fieldKeyPath: ReferenceWritableKeyPath<DemographicsData, DemographicsData.Field<Value>>,
        isRequired: Bool = true,
        @ViewBuilder content: @escaping @MainActor (_ binding: Binding<Value?>, _ state: DemographicsComponentCompletionState) -> Content
    ) {
        self.fieldKeyPath = fieldKeyPath
        self.isRequired = isRequired
        self.content = content
    }
    
    func completionState(in data: DemographicsData) -> DemographicsComponentCompletionState {
        if data.isEmpty(fieldKeyPath) {
            .incomplete(isRequired: isRequired)
        } else {
            .completed
        }
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
    
    func completionState(in data: DemographicsData) -> DemographicsComponentCompletionState {
        content.completionState(in: data)
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
        _TupleComponent(repeat each component)
    }
}


/// A component that does not contain any content.
private typealias _EmptyComponent = _TupleComponent<>


/// A component that represents a tuple of components.
private struct _TupleComponent<each Component: DemographicsComponent>: DemographicsComponent {
    private let component: (repeat each Component)
    
    var view: some SwiftUI.View {
        ViewBuilder.buildBlock(repeat (each component).view)
    }
    
    init(_ component: repeat each Component) {
        self.component = (repeat each component)
    }
    
    func completionState(in data: DemographicsData) -> DemographicsComponentCompletionState {
        var state: DemographicsComponentCompletionState = .completed
        for component in repeat each component {
            state = Self.reduce(state, component.completionState(in: data))
        }
        return state
    }
}

extension _TupleComponent {
    private static func reduce(
        _ lhs: DemographicsComponentCompletionState,
        _ rhs: DemographicsComponentCompletionState
    ) -> DemographicsComponentCompletionState {
        switch (lhs, rhs) {
        case (.completed, .completed):
            .completed
        case (.completed, .incomplete):
            rhs
        case (.incomplete, .completed):
            lhs
        case let (.incomplete(isRequired: lhsIsRequired), .incomplete(isRequired: rhsIsRequired)):
            .incomplete(isRequired: lhsIsRequired || rhsIsRequired)
        }
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
    
    func completionState(in data: DemographicsData) -> DemographicsComponentCompletionState {
        switch storage {
        case .true(let content):
            content.completionState(in: data)
        case .false(let content):
            content.completionState(in: data)
        }
    }
}
