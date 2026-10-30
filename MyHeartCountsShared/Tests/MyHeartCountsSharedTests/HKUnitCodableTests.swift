//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

#if canImport(HealthKit)

import GroveHealthKit
import HealthKit
import Testing


@Suite
struct HKUnitCodableTests {
    private struct TestDescriptor {
        let unitString: String
        let unit: HKUnit
    }
    
    @Test(arguments: [
        TestDescriptor(unitString: "L", unit: .liter()),
        TestDescriptor(unitString: "L/min", unit: .liter() / .minute())
    ])
    private func hkUnitCodable(_ descriptor: TestDescriptor) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let encoded = try encoder.encode(descriptor.unit)
        let string = try #require(String(data: encoded, encoding: .utf8))
        #expect(string == #""\#(descriptor.unitString)""#)
        let decoded = try JSONDecoder().decode(HKUnit.self, from: encoded)
        #expect(decoded == descriptor.unit)
    }
}

#endif
