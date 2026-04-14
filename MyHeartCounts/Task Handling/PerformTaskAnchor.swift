//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

// swiftlint:disable file_types_order

import Foundation
import MHCStudyDefinition
import class ModelsR4.Questionnaire
import MyHeartCountsShared
import ResearchKitSwiftUI // TODO WHY????
import SFSafeSymbols
import SpeziQuestionnaire
import SpeziScheduler
import SpeziStudy
import SpeziStudyDefinition
import SwiftUI


/// Keeps track of the currently active task.
///
/// Modeled as an `@Observable` object injected into the environment so that we can easily set it from within the view hierarchy, without having to deal with view preferences.
@Observable
@MainActor
private final class MHCCurrentlyActiveTask: Sendable {
    fileprivate var task: PerformTask.Task?
}


/// Initiate task actions.
@propertyWrapper
@MainActor
struct PerformTask: DynamicProperty {
    /// A task we might offer the user to perform, that isn't necessarily associated with any particular scheduled event.
    @MainActor
    final class Task: Sendable {
        enum Action: Hashable {
            case answerQuestionnaire(Questionnaire)
            case article(Article)
            case timedWalkTest(TimedWalkingTestConfiguration)
            case ecg
        }
        /// The task's action
        fileprivate let action: Action
        /// The task's completion handler. Will be set to `nil` upon marking the task as completed.
        private var completionHandler: (@Sendable @MainActor (_ success: Bool) -> Void)?
        
        // periphery:ignore - API
        fileprivate var isCompleted: Bool {
            completionHandler == nil
        }
        
        init(action: Action, completionHandler: @escaping @Sendable @MainActor (_ didSucceed: Bool) -> Void) {
            self.action = action
            self.completionHandler = completionHandler
        }
        
        func markCompleted(didSucceed: Bool) {
            completionHandler?(didSucceed)
            completionHandler = nil
        }
    }
    
    @Environment(\.calendar)
    private var cal
    @Environment(MHCCurrentlyActiveTask.self)
    private var currentlyActiveTask
    @Environment(Scheduler.self)
    private var scheduler
    
    var wrappedValue: Self {
        self
    }
    
    /// Initiates a task action, and does not attempt to complete any `Event`s in response.
    ///
    /// - Note: This function does not attempt to auto-complete any `Event`s in response to successful completion of the task.
    ///     If you want this behaviour, use ``callAsFunction(_:context:)`` instead.
    func callAsFunction(_ action: Task.Action) async -> Bool {
        guard currentlyActiveTask.task == nil else {
            print("Error: Attempted to initiate a new active task, while one was already ongoing. Ignoring.")
            return false
        }
        return await withCheckedContinuation { continuation in
            currentlyActiveTask.task = .init(action: action) { success in
                continuation.resume(returning: success)
            }
        }
    }
    
    
    /// Initiates a task action, and attempts to complete a corresponding `Event` in response.
    func callAsFunction(_ action: Task.Action, context: Event? = nil) {
        _Concurrency.Task {
            guard await self(action) else {
                return
            }
            if let context {
                try context.complete()
            } else {
                try reportCompletion(of: action)
            }
        }
    }
    
    
    /// Attempts to find a `Task.Action`'s corresponding `Event`, and marks it as complete if possible.
    func reportCompletion(of action: Task.Action) throws {
        // see if we can find a scheduled event with the same action, and mark it as complete if possible.
        let eventQueryTimeRange: Range<Date> = {
            let start = cal.startOfDay(for: .now)
            guard let end = cal.date(byAdding: .weekOfYear, value: 2, to: start) else {
                fatalError("Unable to compute date")
            }
            return start..<end
        }()
        let candidateEvents = try scheduler.queryEvents(for: eventQueryTimeRange).lazy.filter { !$0.isCompleted }
        let event: Event? = switch action {
        case .ecg:
            candidateEvents.first { event in
                event.task.category == .customActiveTask(.ecg)
            }
        case .timedWalkTest(let test):
            candidateEvents.first { event in
                switch event.task.studyScheduledTaskAction {
                case .promptTimedWalkingTest(let component):
                    component.test == test
                default:
                    false
                }
            }
        case .article, .answerQuestionnaire:
            // we always ignore article actions in here, bc they are only triggered directly in response to
            // the user performing an event, in which case we don't end up in here.
            nil
        }
        guard let event, event.task.completionPolicy.isAllowedToComplete(event: event) else {
            return
        }
        try event.complete()
    }
}


/// Implements logic and code for initiating user-actionable tasks, such as filling out a questionnaire, taking a timed walk test, etc.
private struct UserTaskPerforming: ViewModifier {
    @Environment(MyHeartCountsStandard.self)
    private var standard
    
    @Environment(MHCCurrentlyActiveTask.self)
    private var currentlyActiveTask
    
    func body(content: Content) -> some View {
        @Bindable var currentlyActiveTask = currentlyActiveTask
        content
            .sheet(item: $currentlyActiveTask.task, id: \.action) { task in
                switch task.action {
                case .answerQuestionnaire(let questionnaire):
                    MHCQuestionnaireSheet(questionnaire) { success in
                        task.markCompleted(didSucceed: success)
                        currentlyActiveTask.task = nil
                    }
                case .article(let article):
                    ArticleSheet(article: article)
                        .onAppear {
                            // we consider simply presenting the component as being sufficient to complete the event.
                            // NOTE ISSUE HERE: completing the event puts it into a state where you can't trigger it again (understandably...)
                            // BUT: in this case, we do wanna allow this to happen again! how should we go about this?
                            task.markCompleted(didSucceed: true)
                        }
                case .timedWalkTest(let test):
                    TimedWalkingTestSheet(test) { result in
                        task.markCompleted(didSucceed: result != nil)
                    }
                case .ecg:
                    NavigationStack {
                        ECGInstructionsSheet(shouldOfferManualCompletion: true) { success in
                            task.markCompleted(didSucceed: success)
                        }
                    }
                }
            }
    }
}

extension View {
    /// Designates the view as an anchor for initiating (and continuing) user-prompted tasks, within this part of the view hierarchy.
    ///
    /// Apply this modifier to those parts of the view hierarchy that need to be able to present sheets in response to task actions being initiated via the ``PerformTask`` API.
    /// The modifier is applied once to the root view, and additionally needs to be applied to all views presented as sheets that also need to be able to trigger tasks.
    /// If a task is triggered from within sheet whose view isn't also a taskPerformingAnchor, initiating the task will lead to unexpected behaviour,
    /// causing the first sheet to get dismissed so that the second (task specific) sheet can be displayed.
    func taskPerformingAnchor() -> some View {
        self
            .modifier(UserTaskPerforming())
            .environment(MHCCurrentlyActiveTask())
    }
}


extension PerformTask.Task.Action {
    var title: LocalizedStringResource {
        switch self {
        case .answerQuestionnaire(let questionnaire):
            (questionnaire.title?.value?.string).map { "\($0)" } ?? "Questionnaire"
        case .article(let article):
            "\(article.title)"
        case .timedWalkTest(let test):
            test.displayTitle
        case .ecg:
            "ECG"
        }
    }
    
    var subtitle: LocalizedStringResource? {
        switch self {
        case .answerQuestionnaire:
            "Questionnaire"
        case .article:
            "Article"
        case .timedWalkTest:
            nil
        case .ecg:
            "Electrocardiogram"
        }
    }
    
    var instructions: LocalizedStringResource? {
        switch self {
        case .answerQuestionnaire(let questionnaire):
            (questionnaire.purpose?.value?.string).map { "\($0)" }
        case .article:
            nil // lede?
        case .timedWalkTest:
            nil
        case .ecg:
            nil
        }
    }
    
    var symbol: SFSymbol {
        switch self {
        case .answerQuestionnaire:
            .listBulletClipboard
        case .article:
            .textRectanglePage
        case .timedWalkTest(let test):
            test.kind.symbol
        case .ecg:
            .waveformPathEcgRectangle
        }
    }
    
    /// The text displayed in a button that initiates this action
    var actionLabel: LocalizedStringResource {
        switch self {
        case .answerQuestionnaire:
            "Answer Questionnaire"
        case .article:
            "Read"
        case .timedWalkTest:
            "Take Test"
        case .ecg:
            "Take ECG"
        }
    }
}
