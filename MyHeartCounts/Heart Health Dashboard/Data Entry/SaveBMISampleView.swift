//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import HealthKit
import MyHeartCountsShared
import SFSafeSymbols
import SpeziHealthKit
import SpeziViews
import SwiftUI


struct SaveBMISampleView: View {
    private enum InputMode: Hashable, CaseIterable {
        case bmiDirect
        case weightAndHeight
        
        var displayTitle: String {
            switch self {
            case .bmiDirect: "BMI"
            case .weightAndHeight: "Weight and Height"
            }
        }
    }
    
    @Environment(HealthKit.self)
    private var healthKit
    @Environment(\.dismiss)
    private var dismiss
    @Environment(MyHeartCountsStandard.self)
    private var standard
    
    private let bmiSampleType = SampleType.bodyMassIndex
    private let weightSampleType = SampleType.bodyMass
    private let heightSampleType = SampleType.height
    
    private let weightUnit: HKUnit
    private let heightUnit: HKUnit
    
    @State private var viewState: ViewState = .idle
    @State private var inputMode: InputMode = .weightAndHeight
    @State private var date: Date = .now
    @State private var bmi: Double?
    @State private var weight: Double?
    @State private var height: Double?
    @State private var containsInvalidInput = false
    
    var body: some View {
        Form { // swiftlint:disable:this closure_body_length
            Section {
                Picker("", selection: $inputMode) {
                    ForEach(InputMode.allCases, id: \.self) { mode in
                        Text(mode.displayTitle)
                    }
                }
                .pickerStyle(.segmented)
                .labelsVisibility(.hidden)
                .listRowInsets(.zero)
                .listRowBackground(Color.clear)
            }
            Section {
                DatePicker("Date", selection: $date)
                switch inputMode {
                case .bmiDirect:
                    QuantityInputRow(
                        title: "Body Mass Index",
                        value: $bmi,
                        limits: MHCQuantitySampleType.healthKit(bmiSampleType).inputLimits(in: bmiSampleType.displayUnit),
                        sampleType: .healthKit(bmiSampleType)
                    )
                case .weightAndHeight:
                    QuantityInputRow(
                        title: "Weight",
                        value: $weight,
                        limits: MHCQuantitySampleType.healthKit(weightSampleType).inputLimits(in: weightUnit),
                        sampleType: .healthKit(weightSampleType)
                    )
                    HeightInputRow(
                        title: "Height",
                        quantity: Binding<HKQuantity?> {
                            height.map { HKQuantity(unit: heightUnit, doubleValue: $0) }
                        } set: { newValue in
                            height = newValue?.doubleValue(for: heightUnit)
                        },
                        preferredUnit: heightUnit
                    )
                }
            }
        }
        .navigationTitle("Enter BMI")
        .viewStateAlert(state: $viewState)
        .storeQuantityRowInputsAllValid(in: $containsInvalidInput)
        .toolbar {
            toolbarContent
        }
        .onChange(of: weight, updateBMI)
        .onChange(of: height, updateBMI)
    }
    
    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
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
            .disabled(bmi == nil || containsInvalidInput)
            .buttonStyleGlassProminent()
        }
    }
    
    init() {
        heightUnit = switch LaunchOptions.launchOptions[.heightInputUnitOverride] {
        case .none: heightSampleType.displayUnit
        case .cm: .meterUnit(with: .centi)
        case .feet: .foot()
        }
        weightUnit = switch LaunchOptions.launchOptions[.weightInputUnitOverride] {
        case .none: weightSampleType.displayUnit
        case .kg: .gramUnit(with: .kilo)
        case .lbs: .pound()
        }
    }
    
    private func updateBMI() {
        guard let weight, let height, !containsInvalidInput else {
            return
        }
        // we need to go the extra round through HKQuantity in case weight and height are non-metric
        let weightQuantity = HKQuantity(unit: weightUnit, doubleValue: weight)
        let heightQuantity = HKQuantity(unit: heightUnit, doubleValue: height)
        bmi = weightQuantity.doubleValue(for: .gramUnit(with: .kilo)) / pow(heightQuantity.doubleValue(for: .meter()), 2)
    }
    
    private func save() async throws {
        guard let bmi else {
            return
        }
        var samples: [HKQuantitySample] = [
            HKQuantitySample(
                type: bmiSampleType.hkSampleType,
                quantity: HKQuantity(unit: bmiSampleType.displayUnit, doubleValue: bmi),
                start: date,
                end: date
            )
        ]
        if let height {
            samples.append(HKQuantitySample(
                type: SampleType.height.hkSampleType,
                quantity: HKQuantity(unit: heightUnit, doubleValue: height),
                start: date,
                end: date
            ))
        }
        if let weight {
            samples.append(HKQuantitySample(
                type: SampleType.bodyMass.hkSampleType,
                quantity: HKQuantity(unit: weightUnit, doubleValue: weight),
                start: date,
                end: date
            ))
        }
        try? await healthKit.save(samples)
        let response = try SaveQuantitySampleView.singleSampleDataEntryQuestionnaireResponse(
            for: { () -> SaveQuantitySampleView.Input in
                if let height, let weight {
                    .bmi(
                        bmi: bmi,
                        measurements: (
                            height: HKQuantity(unit: heightUnit, doubleValue: height),
                            weight: HKQuantity(unit: weightUnit, doubleValue: weight)
                        )
                    )
                } else {
                    .bmi(bmi: bmi, measurements: nil)
                }
            }()
        )
        await standard.add(response, for: .bmi)
    }
}
