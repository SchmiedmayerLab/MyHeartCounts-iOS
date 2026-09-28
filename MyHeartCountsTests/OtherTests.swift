//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
@testable import MyHeartCounts
import Testing


@Suite
struct OtherTests {
    @Test
    func healthStatsCalculatorDataSourceCoding() throws {
        typealias DataSourceID = HealthKitStatsCalculator.DataSourceID
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            let encoded = try encoder.encode(DataSourceID.healthKit)
            #expect(String(decoding: encoded, as: UTF8.self) == #""com.apple.HealthKit""#)
        }
        do {
            struct Wrapper: Codable {
                let dataSource: DataSourceID
                let value: Int
            }
            let encoded = try encoder.encode(Wrapper(dataSource: .healthKit, value: 12))
            #expect(String(decoding: encoded, as: UTF8.self) == #"{"dataSource":"com.apple.HealthKit","value":12}"#)
        }
        do {
            let entries: [DataSourceID: [Int]] = [
                .healthKit: [1, 2, 3],
                .fitbit: [4, 5, 6]
            ]
            let encoded = try encoder.encode(entries)
            #expect(String(decoding: encoded, as: UTF8.self) == #"{"com.apple.HealthKit":[1,2,3],"fitbit":[4,5,6]}"#)
            let decoded = try JSONDecoder().decode(type(of: entries), from: encoded)
            #expect(decoded == entries)
        }
    }
}


extension HealthKitStatsCalculator.DataSourceID {
    fileprivate static let fitbit = Self(rawValue: "fitbit")
}
