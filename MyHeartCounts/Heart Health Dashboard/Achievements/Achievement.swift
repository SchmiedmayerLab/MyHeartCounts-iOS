//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

// periphery:ignore:all - currently unused but supported (we keep it in case we want to go down this route in the future)
// swiftlint:disable all

import Foundation
import HealthKit


struct LegacyAchievement: Hashable, Codable, Sendable {
    enum Goal: Hashable, Codable, Sendable {
        enum ReachLevelTarget: Hashable, Codable, Sendable { // swiftlint:disable:this type_contents_order
            case absolute(Double)
            case newMaximum
        }
        case reachLevel(ReachLevelTarget)
        case maintainLevel
    }
    
    let title: String
    let goal: Goal
    
    init(title: String, goal: Goal) {
        self.title = title
        self.goal = goal
    }
}


extension LegacyAchievement {
    enum ResolvedGoal: Hashable, Sendable {
        /// The goal is achieved by reaching (or surpassing) a specified quantity.
        /// - parameter quantity: The target quantity
        /// - parameter invert: Whether the goal should be inverted;
        ///     i.e., whether it should be considered achieved if an actual value is below, rather than above, the quantity.
        /// - parameter baselineQuantity: The quantity we take as the baseline with calculating progress. For non-inverted goals, this should be zero.
        case reachOrSurpass(_ quantity: HKQuantity, invert: Bool = false, baselineQuantity: HKQuantity)
        
        static func reachOrSurpass(_ quantity: HKQuantity, unit: HKUnit) -> Self {
            .reachOrSurpass(quantity, invert: false, baselineQuantity: HKQuantity(unit: unit, doubleValue: 0))
        }
        
        /// Evaluates a concrete value against the goal's value.
        ///
        /// - returns: A `Double` value, indicating how close the `measuredValue` is to the goal's value
        func evaluate(_ measuredQuantity: HKQuantity, unit: HKUnit) -> Double {
            switch self {
            case let .reachOrSurpass(targetQuantity, invert, baselineQuantity):
                let measuredValue = measuredQuantity.doubleValue(for: unit)
                let targetValue = targetQuantity.doubleValue(for: unit)
                if !invert {
                    return measuredValue / targetValue
                } else {
                    let baselineValue = baselineQuantity.doubleValue(for: unit)
                    return baselineValue.distance(to: measuredValue) / baselineValue.distance(to: targetValue)
                }
            }
        }
    }
}
