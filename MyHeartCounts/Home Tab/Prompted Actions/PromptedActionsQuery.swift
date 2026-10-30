//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
@_spi(APISupport)
import Grove
import GroveFoundation
import GroveLocalization
import GroveStudy
import MyHeartCountsShared
import SwiftUI


@MainActor
@propertyWrapper
struct PromptedActions: DynamicProperty {
    enum InclusionCriterion: Equatable {
        /// All ``PromptedAction``s (regardless of their state (e.g., pending, rejected, and completed)) are included in the list.
        case all
        /// Only ``PromptedAction``s with the specified state are included in the list.
        case only(PromptedAction.State, includeRejected: Bool)
    }
    
    // swiftlint:disable attributes
    @StudyManagerQuery private var studyEnrollments: [StudyEnrollment]
    @LocalPreference(.studyActivationDate) private var studyActivationDate
    @LocalPreference(.rejectedHomeTabPromptedActions) private var rejectedActionIds
    // swiftlint:enable attributes
    
    /// selects which actions should be included in the list
    private let inclusionCriterion: InclusionCriterion
    
    @MainActor var wrappedValue: [PromptedAction] {
        actions(filter: .none, matching: inclusionCriterion)
    }
    
    var projectedValue: Self {
        self
    }
    
    // periphery:ignore - false positive
    /// - parameter inclusionCriterion: selects which actions should be included in the list
    init(inclusionCriterion: InclusionCriterion = .only(.pending, includeRejected: false)) {
        self.inclusionCriterion = inclusionCriterion
    }
    
    func reject(_ actionId: PromptedAction.ID) {
        rejectedActionIds.insert(actionId)
    }
    
    func actions(filter: PromptedActionsFilter, matching inclusionCriterion: InclusionCriterion) -> [PromptedAction] {
        switch inclusionCriterion {
        case .all:
            PromptedAction.allActions.filter(filter)
        case let .only(state, includeRejected):
            PromptedAction.allActions.filter { action in
                guard filter.evaluate(action) else {
                    return false
                }
                guard includeRejected || !rejectedActionIds.contains(action.id) else {
                    return false
                }
                return self.state(of: action) == state
            }
        }
    }
    
    func state(of action: PromptedAction) -> PromptedAction.State {
        guard let grove = GroveAppDelegate.grove,
              let enrollment = studyEnrollments.first,
              let studyActivationDate else {
            return .unavailable
        }
        let context = PromptedAction.CurrentStateContext(
            enrollmentDate: enrollment.enrollmentDate,
            studyActivationDate: studyActivationDate,
            grove: grove
        )
        return action.state(context: context)
    }
}

extension LocalPreferenceKeys {
    static let rejectedHomeTabPromptedActions = LocalPreferenceKey<Set<PromptedAction.ID>>(
        "rejectedHomeTabPromptedActions",
        default: []
    )
}


extension Collection where Element == PromptedAction {
    func filter(_ filter: PromptedActionsFilter) -> [PromptedAction] {
        self.filter { filter.evaluate($0) }
    }
}


extension PromptedActionsFilter {
    /// Evaluates the filter against the action, returning `true` if it matched, and `false` otherwise.
    func evaluate(_ action: PromptedAction) -> Bool {
        switch self {
        case .none:
            true
        case .only(let ids):
            ids.contains(action.id)
        case .except(let ids):
            !ids.contains(action.id)
        }
    }
}
