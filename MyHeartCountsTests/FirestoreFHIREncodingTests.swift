//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import FirebaseFirestore
import Foundation
import ModelsR4
@testable import MyHeartCounts
import Testing


@Suite
struct FirestoreFHIREncodingTests {
    private let encoder = Firestore.Encoder()
    
    @Test
    func encodeQuantity() throws {
        let input = Quantity.init(unit: .meter, value: 52)
        let encoded = try encoder.encode(input)
        print(encoded)
        fatalError()
    }
}
