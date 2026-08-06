//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import SpeziFoundation
import UIKit


enum DeviceBattery {
    enum WorkAllowance: Equatable, Sendable {
        case none
        case limited
        case full
    }

    /// Whether the device is currently connected to external power.
    @MainActor static var isCharging: Bool {
        let device = UIDevice.current
        let wasMonitoringBattery = device.isBatteryMonitoringEnabled
        device.isBatteryMonitoringEnabled = true
        defer {
            device.isBatteryMonitoringEnabled = wasMonitoringBattery
        }
        switch device.batteryState {
        case .charging, .full:
            return true
        case .unplugged, .unknown:
            return false
        @unknown default:
            return false
        }
    }

    /// Allows stale jobs to make limited progress on battery without starting every new job after an update.
    @MainActor
    static func workAllowance(lastRun: Date?, staleness: TimeInterval) -> WorkAllowance {
        let now = Date.now
        let effectiveLastRun: Date
        if let lastRun {
            effectiveLastRun = lastRun
        } else if let baseline = LocalPreferencesStore.standard[.deferrableWorkBaseline] {
            effectiveLastRun = baseline
        } else {
            LocalPreferencesStore.standard[.deferrableWorkBaseline] = now
            effectiveLastRun = now
        }
        return workAllowance(
            isCharging: isCharging,
            isLowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
            lastRun: effectiveLastRun,
            now: now,
            staleness: staleness
        )
    }

    static func workAllowance(
        isCharging: Bool,
        isLowPowerModeEnabled: Bool,
        lastRun: Date,
        now: Date,
        staleness: TimeInterval
    ) -> WorkAllowance {
        if isLowPowerModeEnabled {
            return .none
        }
        if isCharging {
            return .full
        }
        return now.timeIntervalSince(lastRun) > staleness ? .limited : .none
    }
}


extension LocalPreferenceKeys {
    static let deferrableWorkBaseline = LocalPreferenceKey<Date?>("deferrableWorkBaseline")
}
