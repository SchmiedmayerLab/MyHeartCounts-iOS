//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveValidation
import GroveViews
import SwiftUI


enum UKPostcode {
    /// Returns the postcode in its canonical form (uppercase, a single space before the inward code), or `nil` if the input isn't a valid UK postcode.
    static func normalized(_ input: String) -> String? {
        let compact = input.replacing(/\s/, with: "").uppercased()
        guard compact.wholeMatch(of: /[A-Z]{1,2}[0-9][A-Z0-9]?[0-9][A-Z]{2}/) != nil || compact == "GIR0AA" else {
            return nil
        }
        return "\(compact.dropLast(3)) \(compact.suffix(3))"
    }
}


struct UKPostcodeTextField: View {
    @Binding private var value: String
    @State private var rawText: String

    @Debounce(.seconds(0.5)) private var debounce // swiftlint:disable:this attributes
    @ValidationState private var validation

    var body: some View {
        VerifiableTextField(text: $rawText, type: .text) {
            Text("Postcode")
        }
        .textContentType(.postalCode)
        .textInputAutocapitalization(.characters)
        .autocorrectionDisabled()
        .validate(input: rawText, rules: [.ukPostcode])
        .receiveValidation(in: $validation)
        .onChange(of: validation) { _, validation in
            if validation.allInputValid {
                debounce {
                    value = UKPostcode.normalized(rawText) ?? ""
                }
            }
        }
    }

    init(value: Binding<String>) {
        _value = value
        _rawText = .init(initialValue: value.wrappedValue)
    }
}


extension ValidationRule {
    static let ukPostcode = ValidationRule(
        rule: { input in
            input.isEmpty || UKPostcode.normalized(input) != nil
        },
        message: "Not a valid UK postcode"
    )
}
