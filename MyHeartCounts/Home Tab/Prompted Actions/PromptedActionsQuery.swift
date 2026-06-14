//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
@_spi(APISupport)
import Spezi
import SpeziFoundation
import SwiftUI


@MainActor
@propertyWrapper
struct PromptedActions: DynamicProperty {
    // swiftlint:disable attributes
    @Environment(\.calendar) private var cal
    @LocalPreference(.studyActivationDate) private var studyActivationDate
    @LocalPreference(.rejectedHomeTabPromptedActions) private var rejectedActionIds
    // swiftlint:enable attributes
    
    /// whether the query should include rejected actions.
    private let includeRejected: Bool
    
    @MainActor var wrappedValue: [PromptedAction] {
        let daysSinceEnrollment = studyActivationDate.map { cal.offsetInDays(from: $0, to: .now) }
        return PromptedAction.allActions.filter { action in
            guard includeRejected || !rejectedActionIds.contains(action.id) else {
                return false
            }
            return action.conditions.allSatisfy { condition in
                switch condition {
                case .daysSinceEnrollment(let range):
                    daysSinceEnrollment.map { range.contains($0) } ?? false
                case .custom(let predicate):
                    SpeziAppDelegate.spezi.map(predicate) ?? false
                }
            }
        }
    }
    
    var projectedValue: Self {
        self
    }
    
    /// - parameter includeRejected: whether the query should include rejected actions.
    init(includeRejected: Bool = false) {
        self.includeRejected = includeRejected
    }
    
    func reject(_ actionId: PromptedAction.ID) {
        rejectedActionIds.insert(actionId)
    }
}

extension LocalPreferenceKeys {
    static let rejectedHomeTabPromptedActions = LocalPreferenceKey<Set<PromptedAction.ID>>(
        "rejectedHomeTabPromptedActions",
        default: []
    )
}
