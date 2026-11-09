//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveValidation
import GroveViews
import SwiftUI


/// A UK health service patient identifier, i.e. an NHS number or a CHI number.
protocol HealthServiceNumber: Codable, Hashable, Sendable {
    static var title: LocalizedStringResource { get }
    static var validationRule: ValidationRule { get }

    var stringValue: String { get }

    init(unchecked stringValue: String)
}


struct HealthServiceNumberTextField<Number: HealthServiceNumber>: View {
    @Binding private var value: Number
    @State private var rawText: String

    @Debounce(.seconds(0.5)) private var debounce // swiftlint:disable:this attributes
    @ValidationState private var validation

    var body: some View {
        VerifiableTextField(text: $rawText, type: .text) {
            Text(Number.title)
        }
        .keyboardType(.numberPad)
        .validate(input: rawText, rules: [Number.validationRule])
        .receiveValidation(in: $validation)
        .onChange(of: validation) { _, validation in
            if rawText.isEmpty || validation.allInputValid {
                debounce {
                    value = Number(unchecked: rawText)
                }
            }
        }
    }

    init(value: Binding<Number>) {
        _value = value
        _rawText = .init(initialValue: value.wrappedValue.stringValue)
    }
}
