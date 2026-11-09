//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveValidation


/// A Community Health Index (CHI) number, the Scottish equivalent of the NHS number.
///
/// A CHI number has 10 digits: the holder's date of birth (DDMMYY), three further digits, and a check digit computed like an NHS number's.
struct CHINumber: HealthServiceNumber {
    static let title: LocalizedStringResource = "CHI Number"
    static let validationRule = ValidationRule(
        rule: { input in
            CHINumber.validate(input)
        },
        message: "Not a valid CHI number"
    )

    let stringValue: String

    init(unchecked stringValue: String) {
        self.stringValue = stringValue
    }

    init?(validating input: String) {
        let input = input.replacing(/[\s-]/, with: "") // remove all space and hyphens
        guard Self.validate(input) else {
            return nil
        }
        self.stringValue = input
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.stringValue = try container.decode(String.self)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.stringValue)
    }
}


extension CHINumber {
    static func validate(_ input: String) -> Bool {
        let input = input.replacing(/[\s-]/, with: "")
        guard NHSNumber.validate(input) else {
            return false
        }
        let digits = input.compactMap(\.wholeNumberValue)
        let dateOfBirth = DateComponents(
            calendar: Calendar(identifier: .gregorian),
            // the CHI number only encodes a two-digit year; 2000 is a leap year, so every DDMM combination that exists in some year is accepted.
            year: 2000,
            month: digits[2] * 10 + digits[3],
            day: digits[0] * 10 + digits[1]
        )
        return dateOfBirth.isValidDate
    }
}
