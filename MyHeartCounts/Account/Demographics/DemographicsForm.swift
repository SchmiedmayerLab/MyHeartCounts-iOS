//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

// swiftlint:disable file_types_order attributes discouraged_optional_boolean

import Foundation
import MyHeartCountsShared
import SFSafeSymbols
import SpeziAccount
import SpeziHealthKit
import SpeziHealthKitUI
import SpeziStudy
import SpeziViews
import SwiftUI


// MARK: DemographicsForm

struct DemographicsForm<Footer: View>: View {
    @Environment(Account.self)
    private var account
    
    @State private var data = DemographicsData()
    @State private var didPopulateData = false
    @Binding private var isComplete: Bool
    
    private let footer: @MainActor () -> Footer
    
    var body: some View {
        Impl(
            didOptInToTrial: account.details?.didOptInToTrial == true,
            isComplete: $isComplete,
            footer: footer
        )
        .environment(data)
        .navigationTitle("Demographics")
        .onAppear {
            if !didPopulateData {
                didPopulateData = true
                data.populate(from: account)
            }
        }
    }
    
    init(
        isComplete: Binding<Bool> = .constant(true),
        @ViewBuilder footer: @MainActor @escaping () -> Footer = { EmptyView() }
    ) {
        self._isComplete = isComplete
        self.footer = footer
    }
}


// MARK: Form Implementation

private struct Impl<Footer: View>: View {
    @Environment(\.locale) private var locale
    @Environment(HealthKit.self) private var healthKit
    @Environment(StudyManager.self) private var studyManager
    @Environment(DemographicsData.self) private var data
    
    let didOptInToTrial: Bool
    @Binding var isComplete: Bool
    let footer: @MainActor () -> Footer
    
    @AccountFeatureFlagQuery(.isDebugModeEnabled) private var debugModeEnabled
    
    @State private var viewState: ViewState = .idle
    @State private var regionOverride: Locale.Region?
    @State private var trialOptInOverride: Bool?
    
    private var region: Locale.Region {
        // if no override is set, we use `studyManager.preferredLocale`,
        // which will be set to the region selected during the onboarding.
        regionOverride ?? studyManager.preferredLocale.region ?? .unitedStates
    }
    
    var body: some View {
        Form {
            if debugModeEnabled {
                debugSection
            }
            Section {
                ReadFromHealthKitButton(viewState: $viewState)
            }
            let layout = demographicsLayout(region: region, didOptInToTrial: trialOptInOverride ?? didOptInToTrial)
            layout.view
                .onChange(of: data.updateCounter, initial: true) { _, _ in
                    isComplete = layout.isComplete(in: data)
                }
            footer()
        }
        .viewStateAlert(state: $viewState)
        .toolbar {
            if ProcessInfo.isBeingUITested {
                testingSupportMenu
            }
        }
    }
    
    private var debugSection: some View {
        Section {
            Picker("Override Region" as String, selection: $regionOverride) {
                ForEach([Locale.Region?.none, .unitedStates, .unitedKingdom, .germany], id: \.self) { region in
                    if let region {
                        Text(region.localizedName(in: locale, includeEmoji: .front))
                    } else {
                        Text("Disable Override" as String)
                    }
                }
            }
            LabeledContent("Effective Region" as String, value: region.localizedName(in: locale, includeEmoji: .front))
            Picker("TrialOptIn" as String, selection: $trialOptInOverride) {
                Text("Default (\(didOptInToTrial))" as String).tag(Bool?.none)
                Divider()
                Text("Force Yes" as String).tag(Bool?.some(true))
                Text("Force No" as String).tag(Bool?.some(false))
            }
        }
    }
}


extension Impl {
    private struct ReadFromHealthKitButton: View {
        @Environment(\.calendar) private var cal
        @Environment(HealthKit.self) private var healthKit
        @Environment(DemographicsData.self) private var data
        @HealthKitCharacteristicQuery(.bloodType) private var healthKitBloodType
        @HealthKitCharacteristicQuery(.dateOfBirth) private var healthKitDateOfBirth
        @HealthKitCharacteristicQuery(.biologicalSex) private var healthKitBiologicalSex
        @HealthKitQuery(.height, timeRange: .ever, limit: 1) private var heightSamples
        @HealthKitQuery(.bodyMass, timeRange: .ever, limit: 1) private var weightSamples
        
        @Binding var viewState: ViewState
        
        var body: some View {
            LabeledButton(
                symbol: .heartTextSquare,
                title: "Read from Health App",
                subtitle: """
                    Use this option to auto-fill Blood Type, Height, Weight, Date of Birth, and Biological Sex, by reading each from the Health app, if available.
                    Alternatively, you can also tap the respective fields below to manually enter a value, or to override the value read from the Health app.
                    """,
                state: $viewState
            ) {
                // this likely isn't necessary but we wanna be safe.
                try await healthKit.askForAuthorization(for: .init(read: [
                    HealthKitCharacteristic.dateOfBirth.hkType,
                    HealthKitCharacteristic.bloodType.hkType,
                    HealthKitCharacteristic.biologicalSex.hkType,
                    SampleType.height.hkSampleType, SampleType.bodyMass.hkSampleType
                ]))
                if cal.isDateInToday(data[\.dateOfBirth] ?? .now), let healthKitDateOfBirth {
                    // we set the time to noon to try to work around time zone issues
                    data[\.dateOfBirth] = cal.makeNoon(healthKitDateOfBirth)
                }
                if data[\.bloodType] == nil, let healthKitBloodType {
                    data[\.bloodType] = healthKitBloodType
                }
                if let heightSample = heightSamples.last {
                    data[\.height] = heightSample.quantity
                }
                if let weightSample = weightSamples.last {
                    data[\.weight] = weightSample.quantity
                }
                if data[\.sexAtBirth] == nil, let healthKitBiologicalSex {
                    data[\.sexAtBirth] = switch healthKitBiologicalSex {
                    case .female: .female
                    case .male: .male
                    case .other: .preferNotToState // not perfect but the best we can do
                    case .notSet: .preferNotToState
                    @unknown default: .preferNotToState
                    }
                }
            }
            .accessibilityLabel("Read from Health App")
        }
    }
}


// MARK: Testing Support

extension Impl {
    private var testingSupportMenu: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                AsyncButton("Add Height & Weight Samples", state: $viewState) {
                    let samples = [
                        HKQuantitySample(
                            type: SampleType.height.hkSampleType,
                            quantity: HKQuantity(unit: .meterUnit(with: .centi), doubleValue: 186),
                            start: .now,
                            end: .now
                        ),
                        HKQuantitySample(
                            type: SampleType.bodyMass.hkSampleType,
                            quantity: HKQuantity(unit: .gramUnit(with: .kilo), doubleValue: 70),
                            start: .now,
                            end: .now
                        )
                    ]
                    try await healthKit.save(samples)
                }
            } label: {
                Text("Testing Support")
            }
        }
    }
}
