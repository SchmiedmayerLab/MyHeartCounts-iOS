//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import SpeziValidation


/// A 10-digit NHS number
struct NHSNumber: Codable, Hashable, Sendable {
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


extension NHSNumber {
    static func checksum(_ input: String) -> Int? {
        let input = input.replacing(/\ |-/, with: "")
        guard input.count == 10 else {
            return nil
        }
        var checksum = 0
        for (offset, char) in input.prefix(9).enumerated() {
            guard char.isASCII, let digit = char.wholeNumberValue else {
                return nil
            }
            checksum += digit * (11 - (offset + 1))
        }
        checksum %= 11
        checksum = 11 - checksum
        return switch checksum {
        case 11: 0
        case 10: nil
        default: checksum
        }
    }
    
    static func validate(_ input: String) -> Bool {
        if let checksum = checksum(input), let lastDigit = input.last?.wholeNumberValue {
            checksum == lastDigit
        } else {
            false
        }
    }
}


extension ValidationRule {
    static let nhsNumber = ValidationRule(
        rule: { input in
            NHSNumber.validate(input)
        },
        message: "Not a valid NHS number"
    )
}
