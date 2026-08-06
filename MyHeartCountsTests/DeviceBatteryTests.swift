//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
@testable import MyHeartCounts
import Testing


struct DeviceBatteryTests {
    struct TestCase: Sendable {
        let isCharging: Bool
        let isLowPowerModeEnabled: Bool
        let age: TimeInterval
        let expected: DeviceBattery.WorkAllowance
    }

    @Test(arguments: [
        TestCase(isCharging: true, isLowPowerModeEnabled: false, age: 0, expected: .full),
        TestCase(isCharging: true, isLowPowerModeEnabled: true, age: TimeConstants.day * 2, expected: .none),
        TestCase(isCharging: false, isLowPowerModeEnabled: false, age: TimeConstants.hour, expected: .none),
        TestCase(isCharging: false, isLowPowerModeEnabled: false, age: TimeConstants.day * 2, expected: .limited),
        TestCase(isCharging: false, isLowPowerModeEnabled: true, age: TimeConstants.day * 2, expected: .none)
    ])
    func workAllowance(testCase: TestCase) {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let allowance = DeviceBattery.workAllowance(
            isCharging: testCase.isCharging,
            isLowPowerModeEnabled: testCase.isLowPowerModeEnabled,
            lastRun: now.addingTimeInterval(-testCase.age),
            now: now,
            staleness: TimeConstants.day
        )

        #expect(allowance == testCase.expected)
    }
}
