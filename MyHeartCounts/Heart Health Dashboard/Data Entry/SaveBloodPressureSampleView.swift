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
import SFSafeSymbols
import SwiftUI


struct SaveBloodPressureSampleView: View {
    private enum Field: Int, Hashable, CaseIterable, Comparable {
        case systolic
        case diastolic
        
        var prev: Self? {
            Self.allCases.last { $0 < self }
        }
        
        var next: Self? {
            Self.allCases.first { $0 > self }
        }
        
        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }
    
    @FocusState private var focusedField: Field?
    @State private var date: Date = .now
    @State private var systolic: Int?
    @State private var diastolic: Int?
    @State private var containsInvalidInput = true
    
    var body: some View {
        HealthDataEntryForm(
            "Enter Blood Pressure",
            // a correlation can't be authorized itself; saving it requires access to its members' types
            healthKitTypes: [SampleType.bloodPressureSystolic.hkSampleType, SampleType.bloodPressureDiastolic.hkSampleType],
            canSave: systolic != nil && diastolic != nil && !containsInvalidInput,
            makeEntry: makeEntry
        ) {
            Section {
                DatePicker("Date", selection: $date)
                makeRow(for: $systolic, sampleType: .bloodPressureSystolic)
                    .focused($focusedField, equals: .systolic)
                makeRow(for: $diastolic, sampleType: .bloodPressureDiastolic)
                    .focused($focusedField, equals: .diastolic)
            }
        }
        .storeQuantityRowInputsAllValid(in: $containsInvalidInput)
        .toolbar {
            focusToolbarItems
        }
        .onAppear {
            guard focusedField == nil else {
                return
            }
            if systolic != nil && diastolic == nil {
                focusedField = .diastolic
            } else {
                focusedField = .systolic
            }
        }
    }
    
    @ToolbarContentBuilder private var focusToolbarItems: some ToolbarContent {
        ToolbarItem(placement: .keyboard) {
            HStack {
                Spacer()
                Button {
                    focusedField = focusedField?.prev
                } label: {
                    Image(systemSymbol: .chevronLeft)
                        .accessibilityLabel("Go to previous field")
                }
                .disabled(focusedField?.prev == nil)
                Button {
                    focusedField = focusedField?.next
                } label: {
                    Image(systemSymbol: .chevronRight)
                        .accessibilityLabel("Go to next field")
                }
                .disabled(focusedField?.next == nil)
            }
        }
    }
    
    private func makeRow(for value: Binding<Int?>, sampleType: SampleType<HKQuantitySample>) -> some View {
        QuantityInputRow(
            title: "\(sampleType.mhcDisplayTitle)",
            value: value,
            limits: MHCQuantitySampleType.healthKit(sampleType).inputLimits(in: sampleType.displayUnit),
            sampleType: .healthKit(sampleType)
        )
    }
    
    private func makeEntry() -> HealthDataEntry? {
        guard let systolic, let diastolic else {
            return nil
        }
        // The user typed the reading in, and the date picker reads the entered time in the current time zone.
        // The correlation and its members must state the same zone, or HealthKit may silently drop the correlation
        // (FB25571287).
        let metadata: [String: Any] = [
            HKMetadataKeyTimeZone: TimeZone.current.identifier,
            HKMetadataKeyWasUserEntered: true
        ]
        let correlation = HKCorrelation(
            type: SampleType.bloodPressure.hkSampleType,
            start: date,
            end: date,
            objects: [
                HKQuantitySample(
                    type: SampleType.bloodPressureSystolic.hkSampleType,
                    quantity: HKQuantity(unit: SampleType.bloodPressureSystolic.displayUnit, doubleValue: Double(systolic)),
                    start: date,
                    end: date,
                    metadata: metadata
                ),
                HKQuantitySample(
                    type: SampleType.bloodPressureDiastolic.hkSampleType,
                    quantity: HKQuantity(unit: SampleType.bloodPressureDiastolic.displayUnit, doubleValue: Double(diastolic)),
                    start: date,
                    end: date,
                    metadata: metadata
                )
            ],
            metadata: metadata
        )
        return .healthKit([correlation])
    }
}
