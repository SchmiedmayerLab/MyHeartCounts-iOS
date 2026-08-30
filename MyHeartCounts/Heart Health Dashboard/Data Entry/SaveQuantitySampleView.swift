//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveHealthKit
import GroveViews
import HealthKit
import MyHeartCountsShared
import SFSafeSymbols
import SwiftUI


struct SaveQuantitySampleView: View {
    @Environment(HealthKit.self)
    private var healthKit
    
    @Environment(\.dismiss)
    private var dismiss
    
    @Environment(MyHeartCountsStandard.self)
    private var standard
    
    private let title: LocalizedStringKey
    private let sampleType: MHCQuantitySampleType
    private let unit: HKUnit
    /// whether the default "save" operation is allowed to fail; in this case a failure will be silently ignored.
    private let isDefaultSaveAllowedToFail: Bool
    private let completionHandler: (@MainActor (QuantitySample) -> Void)?
    @State private var date: Date = .now
    @State private var value: Double?
    @State private var containsInvalidInput = true
    @State private var viewState: ViewState = .idle
    @FocusState private var valueFieldIsFocused: Bool
    
    var body: some View {
        Form {
            Section {
                LabeledContent("Sample Type", value: sampleType.displayTitle)
                DatePicker("Date", selection: $date)
                if sampleType == .healthKit(.height) {
                    let binding = Binding<HKQuantity?> {
                        value.map { HKQuantity(unit: unit, doubleValue: $0) }
                    } set: { newValue in
                        value = newValue?.doubleValue(for: unit)
                    }
                    HeightInputRow(title: "Value", quantity: binding, preferredUnit: unit)
                        .focused($valueFieldIsFocused)
                } else {
                    QuantityInputRow(
                        title: "Value",
                        value: $value,
                        limits: sampleType.inputLimits(in: unit),
                        sampleType: sampleType,
                        unit: unit
                    )
                    .focused($valueFieldIsFocused)
                }
            }
            .storeQuantityRowInputsAllValid(in: $containsInvalidInput)
        }
        .navigationTitle(title)
        .viewStateAlert(state: $viewState)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                DismissButton()
            }
            ToolbarItem(placement: .confirmationAction) {
                AsyncButton(
                    state: $viewState,
                    action: {
                        try await save()
                        dismiss()
                    },
                    label: {
                        Label("Save", systemSymbol: .checkmark)
                    }
                )
                .disabled(value == nil || containsInvalidInput)
                .buttonStyleGlassProminent()
            }
        }
        .onAppear {
            valueFieldIsFocused = true
        }
    }
    
    private init(
        title: LocalizedStringKey?,
        sampleType: MHCQuantitySampleType,
        isDefaultSaveAllowedToFail: Bool,
        completionHandler: (@MainActor (QuantitySample) -> Void)?
    ) {
        self.title = title ?? "Enter \(sampleType.displayTitle)"
        self.sampleType = sampleType
        self.isDefaultSaveAllowedToFail = isDefaultSaveAllowedToFail
        self.completionHandler = completionHandler
        self.unit = switch sampleType {
        case .healthKit(.height):
            switch LaunchOptions.launchOptions[.heightInputUnitOverride] {
            case .none: sampleType.displayUnit
            case .cm: .meterUnit(with: .centi)
            case .feet: .foot()
            }
        case .healthKit(.bodyMass):
            switch LaunchOptions.launchOptions[.weightInputUnitOverride] {
            case .none: sampleType.displayUnit
            case .kg: .gramUnit(with: .kilo)
            case .lbs: .pound()
            }
        default:
            sampleType.displayUnit
        }
    }
    
    
    init(
        _ title: LocalizedStringKey? = nil,
        sampleType: MHCQuantitySampleType
    ) {
        self.init(
            title: title,
            sampleType: sampleType,
            // if we do not have a custom completion handler (that might do stuff with the value entered by the user),
            // the default save operation *must* succeed.
            isDefaultSaveAllowedToFail: false,
            completionHandler: nil
        )
    }
    
    init(
        _ title: LocalizedStringKey? = nil,
        sampleType: MHCQuantitySampleType,
        isDefaultSaveAllowedToFail: Bool,
        completionHandler: @MainActor @escaping (QuantitySample) -> Void
    ) {
        self.init(
            title: title,
            sampleType: sampleType,
            isDefaultSaveAllowedToFail: isDefaultSaveAllowedToFail,
            completionHandler: completionHandler
        )
    }
    
    
    private func save() async throws {
        guard let value = self.value, !containsInvalidInput else {
            return
        }
        switch sampleType {
        case .healthKit(let sampleType):
            let sample = HKQuantitySample(
                type: sampleType.hkSampleType,
                quantity: HKQuantity(unit: unit, doubleValue: value),
                start: self.date,
                end: self.date
            )
            do {
                try await self.healthKit.save(sample)
            } catch {
                if !isDefaultSaveAllowedToFail {
                    throw error
                }
            }
            completionHandler?(.init(sample))
        case .custom(let sampleType):
            let sample = QuantitySample(
                id: UUID(),
                sampleType: .custom(sampleType),
                unit: unit,
                value: value,
                startDate: self.date,
                endDate: self.date
            )
            do {
                try await self.standard.uploadHealthObservation(sample)
            } catch {
                if !isDefaultSaveAllowedToFail {
                    throw error
                }
            }
            completionHandler?(sample)
        }
    }
}


extension HKQuantity {
    func valuesForFeetAndInches() -> (feet: Int, inches: Double) {
        let oneFeetInInches = Measurement(value: 1, unit: UnitLength.feet).converted(to: .inches).value
        let totalFeet = self.doubleValue(for: .foot())
        let totalInches = self.doubleValue(for: .inch())
        let feet = Int(totalFeet)
        guard feet != 0 else {
            return (0, totalInches)
        }
        let inches = totalInches.remainder(dividingBy: Double(feet) * oneFeetInInches).rounded()
        precondition(inches != -1)
        return (feet, inches)
    }
}


extension MHCQuantitySampleType {
    func inputLimits(in unit: HKUnit) -> Range<Double>? {
        switch self {
        case .custom(.bloodLipids):
            30..<400
        case .healthKit(.bloodPressureSystolic):
            60..<250
        case .healthKit(.bloodPressureDiastolic):
            30..<150
        case .healthKit(.bloodGlucose):
            40..<400
        case .healthKit(.height) where unit == .meter():
            0.9..<2.5
        case .healthKit(.height) where unit == .meterUnit(with: .centi):
            90..<250
        case .healthKit(.bodyMass) where unit == .gramUnit(with: .kilo):
            25..<450
        case .healthKit(.bodyMass) where unit == .pound():
            55..<1000
        default:
            nil
        }
    }
}
