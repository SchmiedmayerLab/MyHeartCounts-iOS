//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

// swiftlint:disable file_types_order attributes

import MyHeartCountsShared
import SFSafeSymbols
import SpeziViews
import SwiftUI


/// Small, compact sumary card displaying active ``PromptedAction``s.
///
/// Intended to be displayed in a `Form`, e.g. on the ``HomeTab`` or in the ``AccountSheet``,
/// where it would form a single Section within the `Form`.
/// Tapping the card opens a sheet listing all actions we want to suggest the user perform.
///
/// If no actions are active, this resolves to an empty view.
struct PromptedActionsDigest: View {
    enum Context {
        case completePending
        case viewAll
        
        var filter: PromptedActionsFilter {
            switch self {
            case .completePending:
                LaunchOptions[.promptedActionsFilter]
            case .viewAll:
                .none
            }
        }
    }
    
    @PromptedActions(inclusionCriterion: .only(.pending, includeRejected: false))
    private var actions: [PromptedAction]
    
    private let context: Context
    @State private var isPresentingChecklist = false
    
    var body: some View {
        let hideIfEmpty = switch context {
        case .completePending: true
        case .viewAll: false
        }
        let includeRejectedInDigest = switch context {
        case .completePending: false
        case .viewAll: true
        }
        let actions = $actions.actions(
            filter: context.filter,
            matching: .only(.pending, includeRejected: includeRejectedInDigest)
        )
        // the section stays alive while the checklist sheet is presented (even once the query turns empty),
        // so that the sheet isn't yanked away mid-animation when the last action concludes.
        let shouldDisplay: Bool = { () -> Bool in
            if isPresentingChecklist {
                true
            } else {
                actions.isEmpty ? !hideIfEmpty : true
            }
        }()
        if shouldDisplay {
            Section {
                Button {
                    isPresentingChecklist = true
                } label: {
                    SetupDigestCardLabel(actions: actions)
                }
                .buttonStyle(.plain)
                .accessibilityHint(Text(.setupDigestA11yHint))
                .sheet(isPresented: $isPresentingChecklist) {
                    PromptedActionsSheet(
                        context: context,
                        // we disable rejection if we explicitly want to include rejected actions in the list.
                        rejectAction: { () -> ((PromptedAction.ID) -> Void)? in
                            switch context {
                            case .viewAll:
                                nil
                            case .completePending:
                                { $actions.reject($0) }
                            }
                        }()
                    )
                    .accessibilityIdentifier("PromptedActionsDigestSheet")
                }
                .onChange(of: actions.map(\.id)) { oldValue, newValue in
                    if !oldValue.isEmpty && newValue.isEmpty {
                        // dismiss the sheet if the there are no more actions to display
                        isPresentingChecklist = false
                    }
                }
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listSectionSpacing(.compact)
            .accessibilityIdentifier("PromptedActionsDigest")
        }
    }
    
    init(context: Context) {
        self.context = context
    }
}


/// The actual digest card.
///
/// With zero actions (only reachable while the checklist sheet is still presented), the card shows a transient "all set" state.
private struct SetupDigestCardLabel: View {
    @Environment(\.colorScheme) private var colorScheme

    @ScaledMetric(relativeTo: .headline)
    private var symbolBadgeSize: CGFloat = 33

    let actions: [PromptedAction]

    var body: some View {
        HStack(spacing: 12) {
            if actions.isEmpty {
                allSetBadge
            } else {
                symbolCluster
            }
            VStack(alignment: .leading, spacing: 1.5) {
                Text(title)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !actions.isEmpty {
                DisclosureIndicator()
            }
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.secondarySystemGroupedBackground))
                .overlay {
                    // a whisper of the brand red, so the card reads as "from the study", not as a generic row.
                    RoundedRectangle(cornerRadius: 12)
                        .fill(
                            (actions.isEmpty ? AnyShapeStyle(.green) : AnyShapeStyle(.tint))
                                .opacity(colorScheme == .dark ? 0.07 : 0.04)
                        )
                }
        }
        .contentShape(.rect(cornerRadius: 12))
        .animation(.snappy, value: actions.map(\.id))
    }

    private var title: LocalizedStringResource {
        actions.isEmpty ? .promptedActionsAllSet : .setupDigestTitle
    }

    private var subtitle: LocalizedStringResource {
        .setupDigestSubtitle(numSteps: actions.count)
    }

    private var symbolCluster: some View {
        // if we have <= 3 actions: we show all their icons
        // if we have > 3 actions: we show the first 2, and have an ellipsis to indicate the rest
        let showsEllipsis = actions.count > 3
        let displayedActions = showsEllipsis ? actions.prefix(2) : actions.prefix(3)
        return HStack(spacing: -(symbolBadgeSize / 3)) {
            ForEach(Array(displayedActions.enumerated()), id: \.element.id) { idx, action in
                symbolBadge(action.content.symbol, background: Color.red.gradient)
                    // the first action's badge is topmost, with the following ones tucked behind it
                    .zIndex(Double(displayedActions.count - idx))
            }
            if showsEllipsis {
                symbolBadge(.ellipsis, background: Color(.systemGray2).gradient)
                    .zIndex(0) // all the way at the back
            }
        }
    }

    private var allSetBadge: some View {
        Image(systemSymbol: .checkmark)
            .font(.system(size: symbolBadgeSize * 0.44, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: symbolBadgeSize, height: symbolBadgeSize)
            .background(Color.green.gradient, in: .circle)
            .accessibilityHidden(true)
    }
    
    private func symbolBadge(_ symbol: SFSymbol, background: some ShapeStyle) -> some View {
        Image(systemSymbol: symbol)
            .font(.system(size: symbolBadgeSize * 0.44, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: symbolBadgeSize, height: symbolBadgeSize)
            .background(background, in: .circle)
            .overlay {
                Circle()
                    .strokeBorder(Color(.secondarySystemGroupedBackground), lineWidth: 1.5)
            }
            .accessibilityHidden(true)
    }
}


/// Sheet that displays a list of actions.
private struct PromptedActionsSheet: View {
    @Environment(\.dismiss) private var dismiss
    
    @PromptedActions(inclusionCriterion: .all) private var actions
    let context: PromptedActionsDigest.Context
    
    /// Handler to reject an action. If set to `nil`, the option to reject actions is disabled.
    let rejectAction: ((PromptedAction.ID) -> Void)?
    /// The sheet owns its own view state (rather than sharing the Home tab's),
    /// so that its error alert presents within the sheet and doesn't fight the Home tab's alert.
    @State private var viewState: ViewState = .idle
    
    var body: some View {
        NavigationStack {
            Form {
                switch context {
                case .completePending:
                    section(
                        footer: .setupChecklistFooterPendingOnly,
                        actions: $actions.actions(filter: context.filter, matching: .only(.pending, includeRejected: false))
                    )
                case .viewAll:
                    let pending = $actions.actions(filter: context.filter, matching: .only(.pending, includeRejected: true))
                    let completed = $actions.actions(filter: context.filter, matching: .only(.completed, includeRejected: true))
                    section(footer: .setupChecklistFooterAllActions, actions: pending)
                    section(title: "Completed", footer: pending.isEmpty ? .setupChecklistFooterAllActions : nil, actions: completed)
                }
            }
            .animation(.snappy, value: actions.map(\.id))
            .navigationTitle(.setupChecklistTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    DismissButton()
                        .disabled(viewState != .idle)
                }
            }
        }
        .viewStateAlert(state: $viewState)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onChange(of: actions.isEmpty) { _, isEmpty in
            if isEmpty {
                Task {
                    // give the last row's removal animation a moment before the sheet goes away.
                    try? await Task.sleep(for: .seconds(0.45))
                    dismiss()
                }
            }
        }
    }
    
    private func section(
        title: LocalizedStringResource? = nil,
        footer: LocalizedStringResource? = nil,
        actions: some RandomAccessCollection<PromptedAction>
    ) -> some View {
        ForEach(actions) { action in
            Section {
                PromptedActionRow(
                    action: action,
                    viewState: $viewState,
                    stopSuggesting: rejectAction.map { rejectAction in
                        { withAnimation(.snappy) { rejectAction(action.id) } }
                    }
                )
                .accessibilityIdentifier("PromptedActionRow:\(action.id)")
            } header: {
                if let title, action.id == actions.first?.id {
                    Text(title)
                }
            } footer: {
                if let footer, action.id == actions.last?.id {
                    Text(footer)
                }
            }
        }
    }
}


private struct PromptedActionRow: View {
    @Environment(MyHeartCountsStandard.self)
    private var standard
    
    @ScaledMetric(relativeTo: .headline)
    private var iconBadgeSize: CGFloat = 36
    
    @PromptedActions private var promptedActions
    
    let action: PromptedAction
    @Binding var viewState: ViewState
    let stopSuggesting: (() -> Void)?
    
    @State private var isConfirmingStopSuggesting = false
    @State private var isShowingActionSheet = false
    
    var body: some View {
        let isCompleted = $promptedActions.state(of: action) == .completed
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 11) {
                Image(systemSymbol: isCompleted ? .checkmark : action.content.symbol)
                    .font(.system(size: iconBadgeSize * 0.5, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: iconBadgeSize, height: iconBadgeSize)
                    .background {
                        if isCompleted {
                            Circle().fill(.green.gradient)
                        } else {
                            RoundedRectangle(cornerRadius: 8).fill(.red.gradient)
                        }
                    }
                    .accessibilityHidden(true)
                Text(action.content.title)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.trailing, stopSuggesting == nil ? 0 : 24) // keeps a long title from running underneath the dismiss badge
            Text(action.content.message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !isCompleted {
                enableButton
            }
        }
        // the row manages its insets itself (rather than letting the Form provide them),
        // so that the dismiss badge can sit at a fixed, equal distance from the row's top and trailing edges.
        .padding(EdgeInsets(top: 16, leading: 20, bottom: 16, trailing: 20))
        .overlay(alignment: .topTrailing) {
            if stopSuggesting != nil {
                stopSuggestingButton
                    .padding(12) // equally far from the row's top and trailing edges
            }
        }
        .listRowInsets(EdgeInsets())
        .disabled(viewState == .processing) // don't allow a second action (or a rejection) while one is running
        .accessibilityElement(children: .contain)
        .sheet(isPresented: $isShowingActionSheet) {
            switch action.action {
            case .sheet(let makeSheet):
                makeSheet()
            case .closure:
                EmptyView() // should be unreachable
            }
        }
    }

    private var enableButton: some View {
        AsyncButton(state: $viewState) {
            switch action.action {
            case .closure(let action):
                try await action(standard.spezi)
            case .sheet:
                isShowingActionSheet = true
            }
        } label: {
            Text(action.content.performActionButtonTitle)
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity, minHeight: 27)
        }
        .buttonStyleGlassProminent()
        .buttonBorderShape(.capsule)
        .tint(.red)
        .accessibilityLabel(Text(action.content.title))
    }

    private var stopSuggestingButton: some View {
        Button {
            isConfirmingStopSuggesting = true
        } label: {
            Image(systemSymbol: .xmark)
                .font(.footnote.weight(.bold))
                .foregroundStyle(.secondary)
                .padding(6.5)
                .background(Color(.tertiarySystemFill), in: .circle)
                .padding(4) // extends the tap target beyond the visible badge
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .disabled(stopSuggesting == nil)
        .confirmationDialog(
            .stopSuggestingConfirmTitle,
            isPresented: $isConfirmingStopSuggesting,
            titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                stopSuggesting?()
            } label: {
                Text("Stop Suggesting This")
            }
        } message: {
            Text(.stopSuggestingConfirmMessage)
        }
        .accessibilityLabel(.setupChecklistDontSuggestA11yLabel(for: action.content.title))
    }
}


// MARK: Localized Strings

extension LocalizedStringResource {
    fileprivate static let promptedActionsAllSet = LocalizedStringResource(
        "PROMPTED_ACTIONS_ALL_SET",
        defaultValue: "You're All Set"
    )
    
    fileprivate static let setupDigestTitle = LocalizedStringResource(
        "PROMPTED_ACTIONS_SETUP_DIGEST_TITLE",
        defaultValue: "Complete Your Study Setup"
    )
    
    fileprivate static let setupDigestA11yHint = LocalizedStringResource(
        "PROMPTED_ACTIONS_SETUP_DIGEST_A11Y_HINT",
        defaultValue: "Opens a list of suggested setup steps."
    )
    
    fileprivate static let setupChecklistTitle = LocalizedStringResource(
        "PROMPTED_ACTIONS_SETUP_CHECKLIST_TITLE",
        defaultValue: "Suggested for You"
    )
    
    fileprivate static let setupChecklistFooterPendingOnly = LocalizedStringResource(
        "PROMPTED_ACTIONS_SETUP_CHECKLIST_FOOTER_PENDING_ONLY"
    )
    fileprivate static let setupChecklistFooterAllActions = LocalizedStringResource(
        "PROMPTED_ACTIONS_SETUP_CHECKLIST_FOOTER_ALL_ACTIONS"
    )
    
    fileprivate static let stopSuggestingConfirmTitle = LocalizedStringResource(
        "PROMPTED_ACTIONS_STOP_SUGGESTING_CONFIRM_TITLE",
        defaultValue: "Stop Suggesting This?"
    )
    
    fileprivate static let stopSuggestingConfirmMessage = LocalizedStringResource(
        "PROMPTED_ACTIONS_STOP_SUGGESTING_CONFIRM_MESSAGE",
        defaultValue: "This action remains available through the app's settings."
    )
    
    fileprivate static func setupChecklistDontSuggestA11yLabel(for actionTitle: LocalizedStringResource) -> LocalizedStringResource {
        LocalizedStringResource(
            "PROMPTED_ACTIONS_SETUP_CHECKLIST_DONT_SUGGEST_A11Y",
            defaultValue: "Don't suggest “\(String(localized: actionTitle))” again"
        )
    }
    
    fileprivate static func setupDigestSubtitle(numSteps: Int) -> LocalizedStringResource {
        if numSteps == 0 {
            "PROMPTED_ACTIONS_SETUP_DIGEST_SUBTITLE_ALL_COMPLETED"
        } else {
            LocalizedStringResource(
                "PROMPTED_ACTIONS_SETUP_DIGEST_SUBTITLE",
                defaultValue: "^[\(numSteps) recommended steps](inflect: true) to get the most out of the study"
            )
        }
    }
}
