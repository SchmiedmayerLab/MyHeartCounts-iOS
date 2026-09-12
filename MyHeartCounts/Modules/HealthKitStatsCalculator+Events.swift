//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import HealthKit


extension StatsDocument.Workout {
    init(workout: HKWorkout) {
        self.init(
            id: "healthkit:\(workout.uuid.uuidString.lowercased())",
            date: workout.startDate,
            endDate: workout.endDate,
            duration: workout.duration,
            activityType: workout.workoutActivityType
        )
    }
}


extension StatsDocument.Electrocardiogram {
    init(electrocardiogram: HKElectrocardiogram) {
        self.init(
            id: "healthkit:\(electrocardiogram.uuid.uuidString.lowercased())",
            date: electrocardiogram.startDate,
            endDate: electrocardiogram.endDate
        )
    }
}
