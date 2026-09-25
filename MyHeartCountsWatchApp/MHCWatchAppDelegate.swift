//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Grove
import GroveFoundation
import GroveHealthKit
import HealthKit

final class MHCWatchAppDelegate: GroveAppDelegate {
    override var configuration: Configuration {
        Configuration(standard: MHCWatchAppStandard()) {
            HealthKit {
                RequestReadAccess(
                    quantity: [.heartRate, .activeEnergyBurned, .distanceWalkingRunning]
                )
                RequestWriteAccess(other: [SampleType.workout])
            }
            PhoneConnection()
            WorkoutManager()
        }
    }
}
