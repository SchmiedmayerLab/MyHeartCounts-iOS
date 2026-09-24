//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveSensorKit
import SensorKit


extension SRWristTemperatureSession: @retroactive Identifiable {
    public var id: UUID {
        var hasher = SensorKitSampleIDHasher()
        hasher.combine(self.startDate)
        hasher.combine(self.duration)
        hasher.combine(self.version)
        hasher.combine(self.temperatures.count { _ in true })
        return hasher.finalize()
    }
}
