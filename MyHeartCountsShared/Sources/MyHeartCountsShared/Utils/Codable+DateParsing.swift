//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

public import Foundation


extension JSONEncoder.DateEncodingStrategy {
    /// Creates a `JSONEncoder.DateEncodingStrategy` around a `Date`-supporting `FormatStyle`
    public static func formatStyle(_ format: some FormatStyle<Date, some Encodable & Sendable> & Sendable) -> Self {
        .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(format.format(date))
        }
    }
}


extension JSONDecoder.DateDecodingStrategy {
    /// Creates a `JSONEncoder.DateDecodingStrategy` around a `Date`-supporting `ParseStrategy`
    public static func formatStyle<F: ParseStrategy & Sendable>(
        _ formatStyle: F
    ) -> Self where F.ParseInput: Decodable, F.ParseOutput == Date {
        .custom { decoder in
            try formatStyle.parse(try decoder.singleValueContainer().decode(F.ParseInput.self))
        }
    }
}
