//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import SFSafeSymbols


/// A tracked goal the user can unlock by satisfying some condition.
///
/// - Note: ``Achievement`` conforms to both `Equatable` and `Hashable`.
///     Equality and hashing depend solely on the achievement's ``id``. All other properties are ignored.
///     It is the responsibility of the application to ensure that there never exist two or more achievements with equal ``id``s.
struct Achievement: Identifiable, Sendable {
    typealias MetricValue = Double
    
    enum Kind: Sendable {
        /// An achievement that unlocks based on the events recorded for a trigger.
        ///
        /// - parameter predicate: The function that determines whether the achievement's condition is fulfilled, i.e., whether the achievement is unlocked.
        ///     The trigger events passed to the closure are sorted in increasing order w.r.t. their timestamps.
        ///     Returns the current ``AchievementsManager/AchievementState``, i.e., locked/unlocked.
        case event(trigger: Trigger, predicate: @Sendable (_ events: [AchievementsState.TriggerEvent]) -> AchievementsManager.AchievementState)
        /// An achievement that unlocks when a value associated with some metric reaches a threshold.
        case threshold(metric: Metric, target: MetricValue)
        
        /// An achievement that unlocks when a "thing" happens at least once.
        static func eventOnce(trigger: Trigger) -> Self {
            .counting(trigger: trigger, target: 1)
        }
        
        /// An achievement that unlocks when the amount of times a specific "thing" happened exceeds a threshold.
        static func counting(trigger: Trigger, target: Int) -> Self {
            // Qurstions:
            // 1. do we want to support negative trigger-based achievement kinds?
            //    ie, the achievement would be unlocked as long as you don't have any triggers, but become locked once they exist?
            //    what would the unlockDate be in that case?
            // 2. if there is an "trigger once" achievement that can be unlocked multiple times (bc the trigger is fired multiple times),
            //    should we use the first, or the latest, date for the completion? (currently it's the first, which probably is what
            //    we want most if not all of the time...
            .event(trigger: trigger) { events in
                guard target > 0 else {
                    return .unlocked(unlockDate: .now)
                }
                // assuming that events is sorted in ascending order, this will give us the first event that fulfilled the target count
                if let event = events[safe: target - 1] {
                    return .unlocked(unlockDate: event.timestamp)
                } else {
                    return .locked(
                        progress: Double(events.count) / Double(target),
                        lastUpdate: events.last?.timestamp
                    )
                }
            }
        }
    }
    
    struct Trigger: Identifiable, Hashable, Codable, Sendable {
        enum RecordingMode: String, Hashable, Codable, Sendable {
            /// The ``AchievementsManager`` will keep records of all times the trigger was fired.
            case keepAll = "keep-all"
            /// The ``AchievementsManager`` will keep record of only the first time the trigger was fired.
            case recordOnce = "record-once"
        }
        let id: String
        let recordingMode: RecordingMode
    }
    
    struct Metric: Identifiable, Hashable, Codable, Sendable {
        let id: String
        let rule: ThresholdRule
    }
    
    struct Category: Identifiable, Hashable, Sendable {
        let id: String
        let title: LocalizedStringResource
    }
    
    struct Subcategory: Identifiable, Hashable, Sendable {
        let id: String
        let formsLadder: Bool
    }
    
    enum ThresholdRule: RawRepresentable<String>, Hashable, Codable, Sendable {
        /// A rule that triggers if the metric's observed value is greater than or equal to its target value.
        /// - parameter base: The rule's base value. Used to compute the user's progress in reaching the target.
        ///     For example, a "daily step count" metric would set its base to `0`, since that's the starting point from which any progress should be computed.
        case atLeast(base: MetricValue?)
        /// A rule that triggers if the metric's observed value is less than or equal to its target value.
        /// - parameter base: The rule's base value. Used to compute the user's progress in reaching the target.
        ///     For example, a "resting heart rate" metric could set its base to `90`, since that's the starting point from which any progress should be computed.
        case atMost(base: MetricValue?)
        
        var rawValue: String {
            switch self {
            case .atLeast(.none):
                "atLeast"
            case .atLeast(base: .some(let value)):
                "atLeast(\(value.description))"
            case .atMost(.none):
                "atMost"
            case .atMost(base: .some(let value)):
                "atMost(\(value.description))"
            }
        }
        
        init?(rawValue: String) {
            let name: Substring
            let value: MetricValue?
            if let parenIdx = rawValue.firstIndex(of: "(") {
                guard rawValue.last == ")", let val = MetricValue(rawValue[parenIdx...].dropFirst().dropLast()) else {
                    return nil
                }
                name = rawValue[..<parenIdx]
                value = val
            } else {
                name = rawValue[...]
                value = nil
            }
            switch name {
            case "atLeast":
                self = .atLeast(base: value)
            case "atMost":
                self = .atMost(base: value)
            default:
                return nil
            }
        }
    }
    
    enum Visibility {
        /// The achievement is always fully visible
        case always
        /// The achievement's title/description/symbol/etc are hidden while it isn't yet unlocked.
        case secret
        /// The achievement is never displayed to the user.
        case `internal`
        /// The achievement is hidden until it is the next still-locked level of its ladder.
        ///
        /// Use this for the levels of a progression (a `(category, subcategory)` ladder) so the user only ever
        /// sees the immediate next goal plus the levels they've already unlocked — later levels stay hidden.
        /// - Important: An achievement using this visibility **must** have a ``Achievement/subcategory``;
        ///     "next" is undefined without a ladder.
        case secretUnlessNextInLadder
    }
    
    let id: String
    let category: Category
    let subcategory: Subcategory?
    let kind: Kind
    let title: LocalizedStringResource
    let description: LocalizedStringResource
    let symbol: SFSymbol
    let visibility: Visibility
}


extension Achievement: Hashable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
