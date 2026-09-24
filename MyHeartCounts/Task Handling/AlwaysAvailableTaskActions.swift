//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

// swiftlint:disable attributes function_body_length closure_body_length cyclomatic_complexity

import GroveFoundation
import GroveScheduler
import GroveStudy
import MHCStudyDefinition
import ModelsR4
import SwiftUI


@propertyWrapper
@MainActor
struct AlwaysAvailableTaskActions: DynamicProperty {
    @Environment(StudyManager.self) private var studyManager
    @AccountFeatureFlagQuery(.isDebugModeEnabled) private var debugModeEnabled
    
    var wrappedValue: Self {
        self
    }
    
    /// Determines the available task actions, optionally excluding duplicates based on an array of `Event`s that are displayed alongside these always-available tasks.
    func taskActions(excludingBasedOn events: [Event] = []) -> [[PerformTask.Task.Action]] {
        // All actions we want to offer as "always available"
        let allActions: [[PerformTask.Task.Action]] = Array {
            [.ecg]
            [.timedWalkTest(.sixMinuteWalkTest), .timedWalkTest(.twelveMinuteRunTest)]
            if debugModeEnabled {
                // we offer this as a debug option, to be able to test the 6MWT, without having to wait for 6 minutes.
                [.timedWalkTest(.init(duration: .seconds(30), kind: .walking))]
            }
        }
        guard !events.isEmpty else {
            return allActions
        }
        // filter out anything that's already prompted above
        return allActions.compactMap { (actions: [PerformTask.Task.Action]) in
            let actions = actions.filter { (action: PerformTask.Task.Action) -> Bool in
                switch action {
                case .ecg:
                    !events.contains { $0.task.category == .customActiveTask(.ecg) }
                case .timedWalkTest(let testConfig):
                    !events.contains { event in
                        switch event.task.studyScheduledTaskAction {
                        case .promptTimedWalkingTest(let component):
                            component.test == testConfig
                        default:
                            false
                        }
                    }
                case .answerQuestionnaire(let questionnaire):
                    !events.contains { event in
                        switch event.task.studyScheduledTaskAction {
                        case .answerQuestionnaire(let component):
                            studyManager
                                .studyEnrollments
                                .first?
                                .studyBundle?
                                .questionnaire(for: component.fileRef, in: studyManager.preferredLocale)?
                                .id == questionnaire.id
                        default:
                            false
                        }
                    }
                case .article(let article):
                    !events.contains { event in
                        switch event.task.studyScheduledTaskAction {
                        case .presentInformationalStudyComponent(let component):
                            (studyManager.studyEnrollments.first?.studyBundle?.resolve(component.fileRef, in: studyManager.preferredLocale))
                                .flatMap { try? Data(contentsOf: $0) }
                                .flatMap { String(data: $0, encoding: .utf8) }
                                .flatMap { try? MarkdownDocument.Metadata(parsing: $0) }
                                .map { $0["id"] == article.id.uuidString } ?? false
                        default:
                            false
                        }
                    }
                }
            }
            return actions.isEmpty ? nil : actions
        }
    }
}
