//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveHealthKit
import HealthKit
import SwiftUI


struct QuantityInputRow: View {
    enum AllowsDecimalEntry {
        case automatic
        case yes
        case no // swiftlint:disable:this identifier_name
    }
    
    private let title: LocalizedStringResource
    private let limits: Range<Double>?
    private let sampleType: MHCQuantitySampleType
    @Binding private var value: Double?
    private let unit: HKUnit?
    private let allowsDecimalEntry: Bool
    // Note: using a NumberFormatter() instead of the new `FloatingPointFormatStyle<Double>.number` API,
    // because of https://github.com/swiftlang/swift-foundation/issues/135
    private let formatter = NumberFormatter()
    
    var body: some View {
        VStack {
            HStack {
                Text(title)
                TextField(value: $value, formatter: formatter, prompt: Text("0")) {
                    Text(title)
                }
                .accessibilityIdentifier("QuantityDataEntry:\(sampleType.displayTitle)")
                .multilineTextAlignment(.trailing)
                .keyboardType(allowsDecimalEntry ? .decimalPad : .numberPad)
                .preference(key: ContainsInvalidInputPreferenceKey.self, value: inputIsOutOfLimits)
                if let unit, unit != .count() {
                    Text(unit.unitString)
                        .foregroundStyle(.secondary)
                }
            }
            if inputIsOutOfLimits, let limits {
                let fmt = {
                    // swiftlint:disable:next legacy_objc_type
                    formatter.string(from: NSNumber(value: $0 as Double)) ?? String($0)
                }
                Text("Only values from \(fmt(limits.lowerBound)) to \(fmt(limits.upperBound)) are allowed")
                    .font(.caption)
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }
    
    private var inputIsOutOfLimits: Bool {
        if let value, let limits, !limits.contains(value) {
            true
        } else {
            false
        }
    }
    
    // MARK: Double
    
    init(
        title: LocalizedStringResource,
        value: Binding<Double?>,
        limits: Range<Double>?,
        sampleType: MHCQuantitySampleType,
        unit: HKUnit? = nil,
        allowsDecimalEntry: AllowsDecimalEntry = .automatic
    ) {
        self.title = title
        self.limits = limits
        self._value = value
        self.sampleType = sampleType
        self.unit = unit ?? sampleType.displayUnit
        self.allowsDecimalEntry = switch allowsDecimalEntry {
        case .automatic:
            !sampleType.prefersNonDecimalValues
        case .yes:
            true
        case .no:
            false
        }
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 2 // make this dependent on the context?!
    }
    
    
    // MARK: Int
    
    init(
        title: LocalizedStringResource,
        value: Binding<Int?>,
        limits: Range<Double>?,
        sampleType: MHCQuantitySampleType,
        unit: HKUnit? = nil,
        allowsDecimalEntry: AllowsDecimalEntry = .automatic
    ) {
        self.title = title
        self.limits = limits
        self._value = Binding<Double?> {
            value.wrappedValue.flatMap { Double(exactly: $0) }
        } set: { newValue in
            value.wrappedValue = newValue.flatMap { $0.isNaN ? nil : Int($0) }
        }
        self.sampleType = sampleType
        self.unit = unit ?? sampleType.displayUnit
        self.allowsDecimalEntry = switch allowsDecimalEntry {
        case .automatic:
            !sampleType.prefersNonDecimalValues
        case .yes:
            true
        case .no:
            false
        }
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
    }
}


extension QuantityInputRow {
    struct ContainsInvalidInputPreferenceKey: PreferenceKey {
        static let defaultValue = false
        
        static func reduce(value: inout Bool, nextValue: () -> Bool) {
            value = value || nextValue()
        }
    }
}


extension View {
    func storeQuantityRowInputsAllValid(in containsInvalidInput: Binding<Bool>) -> some View {
        self.onPreferenceChange(QuantityInputRow.ContainsInvalidInputPreferenceKey.self) {
            containsInvalidInput.wrappedValue = $0
        }
    }
}


extension MHCQuantitySampleType {
    /// whether the sample type prefers non-decimal values (i.e., natural numbers) in its data entry.
    var prefersNonDecimalValues: Bool {
        switch self {
        case .healthKit(let sampleType):
            // we only consider the ones we actually support data entry for in MHC...
            switch sampleType {
            case .stepCount, .bloodGlucose:
                true
            default:
                false
            }
        case .custom(.bloodLipids):
            true
        default:
            true
        }
    }
}
