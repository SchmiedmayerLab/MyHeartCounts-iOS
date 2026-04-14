//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

// swiftlint:disable file_length attributes

import Algorithms
import Foundation
import MHCStudyDefinition
import OSLog
import ResearchKitSwiftUI // TODO WHY????
import SFSafeSymbols
import SpeziFoundation
import SpeziQuestionnaire
import SpeziScheduler
import SpeziSchedulerUI
import SpeziStudy
import SpeziStudyDefinition
import SpeziViews
import SwiftUI


struct TasksList: View {
    enum TimeRange {
        /// The time range starting today, and going `numDays` days into the future.
        case days(_ numDays: Int)
        /// The time range starting today, and going `numWeeks` weeks into the future.
        case weeks(_ numWeeks: Int)
        /// The time range starting today, and going `numMonths` months into the future.
        case months(_ numMonths: Int)
        
        /// The time range encompassing all of today.
        static let today = Self.days(1)
        
        // periphery:ignore - unused but we want to keep it around
        /// The time range starting today, and going a week into the future.
        static let nextWeek = Self.weeks(1)
        
        // periphery:ignore - unused but we want to keep it around
        /// The time range starting today, and going 14 days into the future.
        static let fortnight = Self.weeks(2)
        
        // periphery:ignore - unused but we want to keep it around
        /// The time range starting today, and going a month into the future.
        static let month = Self.months(1)
    }
    
    enum Mode {
        /// The list should display a list of upcoming Tasks
        case upcoming(includeIndefinitePastTasks: Bool, showFallbackTasks: Bool)
        /// The list should display a list of missed but not yet expired Tasks
        case missed
    }
    
    /// How the individual events in the list should be grouped.
    enum EventGroupingConfig {
        case none
        case byDay
    }
    
    enum HeaderConfig {
        case none
        case custom(LocalizedStringResource, subtitle: LocalizedStringResource? = nil)
        case timeRange(subtitle: SubtitleMode)
        
        enum SubtitleMode {
            case show, hide, automatic
        }
    }
    
    struct NoTasksMessageLabels {
        let title: LocalizedStringResource
        let subtitle: LocalizedStringResource
        
        init(
            title: LocalizedStringResource,
            subtitle: LocalizedStringResource = "All tasks have been completed!"
        ) {
            self.title = title
            self.subtitle = subtitle
        }
    }
    
    
    @Environment(\.calendar) private var cal
    @Environment(StudyManager.self) private var studyManager
    @PerformTask private var performTask
    
    private let mode: Mode
    private let timeRange: TimeRange
    private let headerConfig: HeaderConfig
    private let eventGroupingConfig: EventGroupingConfig
    private let noTasksMessageLabels: NoTasksMessageLabels
    
    var body: some View {
        header
        tasksList
            .injectingCustomTaskCategoryAppearances()
            .taskCategoryAppearance(for: .customActiveTask(.ecg), label: "Electrocardiogram", image: .system(.waveformPathEcgRectangle))
    }
    
    @ViewBuilder private var header: some View {
        let (title, subtitle) = headerContents
        UpcomingTasksTab.sectionHeader(
            title: title,
            subtitle: subtitle
        )
    }
    
    private var headerContents: (LocalizedStringResource, LocalizedStringResource?) {
        switch headerConfig {
        case .none:
            return ("", nil)
        case let .custom(title, subtitle):
            return (title, subtitle)
        case .timeRange(let subtitleMode):
            let title: LocalizedStringResource
            let needsSubtitle: Bool
            switch timeRange {
            case .days(1):
                title = "Today"
                needsSubtitle = false
            case .days(let numDays):
                title = "Next \(numDays) Days"
                 needsSubtitle = true
            case .weeks(let numWeeks):
                title = "Next \(numWeeks) Weeks"
                 needsSubtitle = true
            case .months(let numMonths):
                title = "Next \(numMonths) Months"
                 needsSubtitle = true
            }
            switch subtitleMode {
            case .automatic where needsSubtitle, .show:
                let timeRange = Self.effectiveTimeRange(for: timeRange, cal: cal)
                let start = timeRange.lowerBound.formatted(date: .numeric, time: .omitted)
                let end = timeRange.upperBound.addingTimeInterval(-1).formatted(date: .numeric, time: .omitted)
                return (title, "\(start) – \(end)")
            case .hide, .automatic:
                return (title, nil)
            }
        }
    }
    
    @ViewBuilder private var tasksList: some View {
        let effectiveTimeRange = Self.effectiveTimeRange(for: timeRange, cal: cal)
        switch mode {
        case let .upcoming(includeIndefinitePastTasks, showFallbackTasks):
            if includeIndefinitePastTasks, let dateOfEnrollment = studyManager.studyEnrollments.first?.enrollmentDate {
                UpcomingEventsQueryWithMissedPastEvents(effectiveTimeRange, dateOfEnrollment: dateOfEnrollment) { events in
                    Impl(
                        events: events,
                        showFallbackTasks: showFallbackTasks,
                        eventGroupingConfig: eventGroupingConfig,
                        noTasksMessageLabels: noTasksMessageLabels
                    ) {
                        handleAction($0)
                    }
                }
            } else {
                UpcomingEventsQuery(effectiveTimeRange) { events in
                    Impl(
                        events: events,
                        showFallbackTasks: showFallbackTasks,
                        eventGroupingConfig: eventGroupingConfig,
                        noTasksMessageLabels: noTasksMessageLabels
                    ) {
                        handleAction($0)
                    }
                }
            }
        case .missed:
            MissedEventsQuery(effectiveTimeRange) { events in
                Impl(
                    events: events,
                    showFallbackTasks: false,
                    eventGroupingConfig: eventGroupingConfig,
                    noTasksMessageLabels: noTasksMessageLabels
                ) {
                    handleAction($0)
                }
            }
        }
    }
    
    init(
        mode: Mode,
        timeRange: TimeRange,
        headerConfig: HeaderConfig = .timeRange(subtitle: .automatic),
        eventGroupingConfig: EventGroupingConfig,
        noTasksMessageLabels: NoTasksMessageLabels
    ) {
        self.mode = mode
        self.timeRange = timeRange
        self.headerConfig = headerConfig
        self.eventGroupingConfig = eventGroupingConfig
        self.noTasksMessageLabels = noTasksMessageLabels
    }
}


extension TasksList {
    private func handleAction(_ taskToPerform: Impl.TaskToPerform) {
        switch taskToPerform {
        case let .regular(action, event, context, shouldCompleteEvent):
            handleAction(action, for: event, context: context, shouldComplete: shouldCompleteEvent)
        case .unscheduled(let action):
            performTask(action)
        }
    }
    
    private func handleAction( // swiftlint:disable:this function_body_length cyclomatic_complexity
        _ action: StudyManager.ScheduledTaskAction,
        for event: Event,
        context: Task.Context.StudyContext,
        shouldComplete: Bool
    ) {
        switch action {
        case .presentInformationalStudyComponent(let component):
            guard let enrollment = studyManager.enrollment(withId: context.enrollmentId),
                  let studyBundle = enrollment.studyBundle,
                  let article = Article(component, in: studyBundle, locale: studyManager.preferredLocale) else {
                logger.error("Error fetching & loading & procesing Article")
                return
            }
            _Concurrency.Task {
                guard await performTask(.article(article)) else {
                    return
                }
                if shouldComplete {
                    try event.complete()
                }
            }
        case .answerQuestionnaire(let component):
            guard let enrollment = studyManager.enrollment(withId: context.enrollmentId),
                  let studyBundle = enrollment.studyBundle,
                  let questionnaire = studyBundle.questionnaire(for: component.fileRef, in: studyManager.preferredLocale) else {
                logger.error("Unable to find SPC")
                return
            }
            _Concurrency.Task {
                guard await performTask(.answerQuestionnaire(questionnaire)) else {
                    return
                }
                if shouldComplete {
                    try event.complete()
                }
            }
        case .promptTimedWalkingTest(let component):
            _Concurrency.Task {
                guard await performTask(.timedWalkTest(component.test)) else {
                    return
                }
                if shouldComplete {
                    try event.complete()
                }
            }
        case .performCustomActiveTask(let component):
            switch component.activeTask {
            case .ecg:
                _Concurrency.Task {
                    guard await performTask(.ecg) else {
                        return
                    }
                    if shouldComplete {
                        try event.complete()
                    }
                }
            default:
                logger.warning("Unhandled custom active task: \(component.activeTask.identifier)")
            }
        }
    }
}


extension StudyDefinition.CustomActiveTaskComponent.ActiveTask {
    // periphery:ignore - implicitly called
    static func ~= (pattern: Self, value: Self) -> Bool {
        pattern.identifier == value.identifier
    }
}

extension TasksList {
    static func effectiveTimeRange(for timeRange: TimeRange, cal: Calendar) -> Range<Date> {
        switch timeRange {
        case .days(let numDays):
            let start = cal.startOfDay(for: .now)
            let end = cal.date(byAdding: .day, value: numDays, to: start) ?? start
            return start..<end
        case .weeks(let numWeeks):
            let start = cal.startOfDay(for: .now)
            let end = cal.date(byAdding: .weekOfYear, value: numWeeks, to: start) ?? start
            return start..<end
        case .months(let numMonths):
            let start = cal.startOfDay(for: .now)
            let end = cal.date(byAdding: .month, value: numMonths, to: start) ?? start
            return start..<end
        }
    }
}


extension TasksList {
    private struct UpcomingEventsQuery<Content: View>: View {
        @EventQuery private var events: [Event]
        private let content: @MainActor ([Event]) -> Content
        
        var body: some View {
            content(events)
        }
        
        init(_ timeRange: Range<Date>, @ViewBuilder content: @escaping @MainActor ([Event]) -> Content) {
            _events = .init(in: timeRange)
            self.content = content
        }
    }
    
    
    private struct UpcomingEventsQueryWithMissedPastEvents<Content: View>: View {
        @MHCTodaysEventsQuery private var events: [Event]
        private let content: @MainActor ([Event]) -> Content
        
        var body: some View {
            content(events)
        }
        
        init(_ timeRange: Range<Date>, dateOfEnrollment: Date, @ViewBuilder content: @escaping @MainActor ([Event]) -> Content) {
            _events = .init(timeRange, dateOfEnrollment: dateOfEnrollment)
            self.content = content
        }
    }
    
    
    private struct MissedEventsQuery<Content: View>: View {
        @MissedEventQuery private var events: [Event]
        private let content: @MainActor ([Event]) -> Content
        
        var body: some View {
            content(events)
        }
        
        init(_ timeRange: Range<Date>, @ViewBuilder content: @escaping @MainActor ([Event]) -> Content) {
            _events = .init(in: timeRange)
            self.content = content
        }
    }
}


extension TasksList {
    private enum EventInteractionConfig: Hashable {
        /// We don't allow the user to perform the event's associated action.
        case disabled
        /// We allow the user to perform the event's associated action.
        /// - parameter shouldComplete: whether the user successfully performing the action should result in the event getting marked as completed.
        case canPerform(shouldComplete: Bool)
        
        var canPerform: Bool {
            switch self {
            case .disabled: false
            case .canPerform: true
            }
        }
        var shouldComplete: Bool {
            switch self {
            case .disabled:
                false
            case .canPerform(let shouldComplete):
                shouldComplete
            }
        }
    }
}


extension TasksList {
    private struct Impl: View {
        typealias SelectionHandler = @MainActor (TaskToPerform) -> Void
        
        enum TaskToPerform {
            case regular(
                action: StudyManager.ScheduledTaskAction,
                event: Event,
                context: Task.Context.StudyContext,
                shouldCompleteEvent: Bool
            )
            case unscheduled(PerformTask.Task.Action)
        }
        
        private struct SectionedEvents {
            let startOfDay: Date
            let events: [Event]
        }
        
        @Environment(\.calendar) private var cal
        @AlwaysAvailableTaskActions private var alwaysAvailableTaskActions
        private let events: [Event]
        private let showFallbackTasks: Bool
        private let eventGroupingConfig: TasksList.EventGroupingConfig
        private let noTasksMessageLabels: NoTasksMessageLabels
        private let selectionHandler: SelectionHandler
        
        var body: some View {
            if !events.isEmpty {
                let eventsByDay = eventsByDay
                switch eventGroupingConfig {
                case .none:
                    ForEach(eventsByDay, id: \.startOfDay) { sectionedEvents in
                        ForEach(sectionedEvents.events) { event in
                            Section {
                                tile(for: event)
                            }
                            .listSectionSpacing(.compact)
                        }
                    }
                case .byDay:
                    ForEach(eventsByDay, id: \.startOfDay) { sectionedEvents in
                        Section {
                            ForEach(data: sectionedEvents.events) { (event: Event) in
                                tile(for: event)
                            }
                        } header: {
                            Text(sectionedEvents.startOfDay.formatted(date: .long, time: .omitted))
                        }
                    }
                }
            } else {
                Section {
                    ContentUnavailableView(
                        noTasksMessageLabels.title.localizedString(),
                        systemSymbol: .partyPopper,
                        description: Text(noTasksMessageLabels.subtitle)
                    )
                }
            }
            if showFallbackTasks || events.isEmpty {
                UpcomingTasksTab.sectionHeader(
                    title: "Other Tasks",
                    subtitle: "Always Available"
                )
                fallbackSections
            }
        }
        
        private var eventsByDay: [SectionedEvents] {
            events.chunked { cal.isDate($0.occurrence.start, inSameDayAs: $1.occurrence.start) }
                // SAFETY: the chunking guarantees that the slices aren't empty.
                // we need to use `.first` instead of `[0]`, since the slices share the indices.
                // swiftlint:disable:next force_unwrapping
                .map { SectionedEvents(startOfDay: cal.startOfDay(for: $0.first!.occurrence.start), events: Array($0)) }
        }
        
        @ViewBuilder private var fallbackSections: some View {
            let actions = alwaysAvailableTaskActions.taskActions(excludingBasedOn: events).flatMap(\.self)
            ForEach(actions, id: \.self) { action in
                Section {
                    FakeEventTile(
                        symbol: action.symbol,
                        title: action.title,
                        subtitle: action.subtitle,
                        instructions: action.instructions,
                        actionLabel: action.actionLabel
                    ) {
                        selectionHandler(.unscheduled(action))
                    }
                }
                .listSectionSpacing(.compact)
            }
        }
        
        
        init(
            events: [Event],
            showFallbackTasks: Bool,
            eventGroupingConfig: TasksList.EventGroupingConfig,
            noTasksMessageLabels: NoTasksMessageLabels,
            selectionHandler: @escaping SelectionHandler
        ) {
            self.events = events
            self.showFallbackTasks = showFallbackTasks
            self.eventGroupingConfig = eventGroupingConfig
            self.noTasksMessageLabels = noTasksMessageLabels
            self.selectionHandler = selectionHandler
        }
        
        @ViewBuilder
        private func tile(for event: Event) -> some View {
            if let context = event.task.studyContext,
               let action = event.task.studyScheduledTaskAction {
                let interactions = eventInteractionConfig(for: event)
                InstructionsTile(event, footerVisibility: !event.isCompleted || interactions.canPerform ? .showAlways : .hideIfCompleted) {
                    DefaultTileHeader(event)
                } footer: {
                    let buttonLabel = eventButtonTitle(for: event)
                    let accessibilityLabel: LocalizedStringResource = if let buttonLabel {
                        switch event.task.category {
                        case .customActiveTask(.ecg):
                            buttonLabel
                        default:
                            // The buttonLabel is a prompt for an action (eg "Answer Questionnaire" or "Read Article),
                            // and we then add as context the thing this action would relate to.
                            "\(buttonLabel): \(String(localized: event.task.title))"
                        }
                    } else {
                        "Perform Task: \(String(localized: event.task.title))"
                    }
                    EventActionButton(event: event, label: buttonLabel) {
                        selectionHandler(.regular(
                            action: action,
                            event: event,
                            context: context,
                            shouldCompleteEvent: !event.isCompleted || interactions.shouldComplete
                        ))
                    }
                    .accessibilityLabel(accessibilityLabel)
                    // not perfect bc the part after the label will still be incorrectly localized
                    // (we can't easily fix this bc it's the task title, which is hardcoded to a localization...)
                    .accessibilityIdentifier(accessibilityLabel.localizedString(for: .enUS))
                }
            } else {
                InstructionsTile(event)
            }
        }
        
        private func eventButtonTitle(for event: Event) -> LocalizedStringResource? {
            enum EventActionState {
                case disabled
                case enabled(wouldBeFirstCompletion: Bool)
            }
            let state: EventActionState = switch eventInteractionConfig(for: event) {
            case .disabled: .disabled
            case .canPerform: .enabled(wouldBeFirstCompletion: !event.isCompleted)
            }
            return switch (event.task.category, state) {
            case (.informational, .disabled), (.informational, .enabled(wouldBeFirstCompletion: true)):
                "Read Article"
            case (.informational, .enabled(wouldBeFirstCompletion: false)):
                "Read Article Again"
            case (.questionnaire, .disabled), (.questionnaire, .enabled(wouldBeFirstCompletion: true)):
                "Answer Survey"
            case (.questionnaire, .enabled(wouldBeFirstCompletion: false)):
                "Answer Survey Again"
            case (.timedWalkingTest, .disabled), (.timedWalkingTest, .enabled(wouldBeFirstCompletion: true)),
                (.timedRunningTest, .disabled), (.timedRunningTest, .enabled(wouldBeFirstCompletion: true)):
                "Take Test"
            case (.timedWalkingTest, .enabled(wouldBeFirstCompletion: false)), (.timedRunningTest, .enabled(wouldBeFirstCompletion: false)):
                "Take Test Again"
            case (.customActiveTask(.ecg), _):
                "Take ECG"
            default:
                nil
            }
        }
        
        
        private func eventInteractionConfig(for event: Event) -> EventInteractionConfig {
            let numDaysAway = abs(cal.offsetInDays(from: event.occurrence.start, to: .now))
            let activeTasks = [Task.Category.timedWalkingTest, .timedRunningTest]
            let isActiveTask = event.task.category.map { activeTasks.contains($0) } ?? false
            return if !event.isCompleted {
                // the event in question has not been completed yet.
                if cal.isDateInToday(event.occurrence.start) {
                    if let earliestCompletionDate = event.task.completionPolicy.dateOnceCompletionIsAllowed(for: event),
                       earliestCompletionDate <= .now {
                        .canPerform(shouldComplete: true)
                    } else {
                        .disabled
                    }
                } else {
                    .canPerform(shouldComplete: !isActiveTask && numDaysAway <= 14)
                }
            } else { // the event has already been completed
                // NOTE: the checks in this branch will only every apply to already-completed events that were scheduled for the current day;
                // if they're older than that the TaskList won't be displaying them in the first place.
                if isActiveTask {
                    // we always allow active tasks to be repeated.
                    .canPerform(shouldComplete: false)
                } else {
                    .disabled
                }
            }
        }
    }
}


extension TasksList {
    private struct FakeEventTile: View {
        private let symbol: SFSymbol
        private let title: LocalizedStringResource
        private let subtitle: LocalizedStringResource?
        private let instructions: LocalizedStringResource?
        private let actionLabel: LocalizedStringResource
        private let action: @MainActor () -> Void
        
        var body: some View {
            SimpleTile(alignment: .leading) {
                TileHeader(alignment: .leading) {
                    Image(systemSymbol: symbol)
                        .foregroundColor(.accentColor)
                        .accessibilityHidden(true)
                        .font(.custom("Task Icon", size: 30, relativeTo: .headline))
                        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
                } title: {
                    Text(title)
                } subheadline: {
                    if let subtitle {
                        Text(subtitle)
                    }
                }
            } body: {
                if let instructions {
                    Text(instructions)
                }
            } footer: {
                Button {
                    action()
                } label: {
                    Text(actionLabel)
                        .frame(maxWidth: .infinity, minHeight: 30)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        
        init(
            symbol: SFSymbol,
            title: LocalizedStringResource,
            subtitle: LocalizedStringResource? = nil,
            instructions: LocalizedStringResource? = nil,
            actionLabel: LocalizedStringResource,
            action: @escaping @MainActor () -> Void
        ) {
            self.symbol = symbol
            self.title = title
            self.subtitle = subtitle
            self.instructions = instructions
            self.actionLabel = actionLabel
            self.action = action
        }
    }
}


extension SwiftUI.ForEach {
    // we need this, for some unknown reason, to explicitly select the correct overload in one place above,
    // where, for also unknown reasons, the compiler would otherwise select the @ChartContentBuilder init.
    fileprivate init(
        data: Data,
        @ViewBuilder content: @escaping (Data.Element) -> Content
    ) where Data: RandomAccessCollection, ID == Data.Element.ID, Data.Element: Identifiable, Content: View {
        self.init(data) { content($0) }
    }
}


extension EventActionButton {
    init(event: Event, label: LocalizedStringResource?, action: @escaping @MainActor () -> Void) {
        if let label {
            self.init(event: event, label, action: action)
        } else {
            self.init(event: event, action: action)
        }
    }
}
