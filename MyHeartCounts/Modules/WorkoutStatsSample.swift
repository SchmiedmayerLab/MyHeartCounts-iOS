//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import HealthKit


/// An individual workout, retaining active duration independently of its wall-clock interval.
struct WorkoutStatsSample: Hashable, Sendable {
    let id: String
    let date: Date
    let endDate: Date
    /// Active duration in seconds; pauses are excluded by the writer.
    let duration: Double
    let activityType: HKWorkoutActivityType
}
