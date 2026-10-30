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


struct NHSNumberTextField: View {
    @Binding private var value: NHSNumber
    @State private var rawText: String
    
    @Debounce(.seconds(0.5)) private var debounce // swiftlint:disable:this attributes
    @ValidationState private var validation
    
    var body: some View {
        VerifiableTextField(text: $rawText, type: .text) {
            Text("NHS Number")
        }
        .keyboardType(.numberPad)
        .validate(input: rawText, rules: [.nhsNumber])
        .receiveValidation(in: $validation)
        .onChange(of: validation) { _, validation in
            if rawText.isEmpty || validation.allInputValid {
                debounce {
                    value = NHSNumber(unchecked: rawText)
                }
            }
        }
    }
    
    init(value: Binding<NHSNumber>) {
        _value = value
        _rawText = .init(initialValue: value.wrappedValue.stringValue)
    }
}
