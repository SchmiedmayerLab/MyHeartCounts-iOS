//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2023 Stanford University
//
// SPDX-License-Identifier: MIT
//

import FirebaseCore
import FirebaseFunctions
import SFSafeSymbols
import SpeziAccount
import SpeziHealthKitBulkExport
import SpeziLicense
import SpeziSensorKit
import SpeziStudy
import SpeziViews
import SwiftUI


struct AccountSheet: View {
    private let dismissAfterSignIn: Bool
    // swiftlint:disable attributes
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettingsApp) private var openSettingsApp
    @Environment(Account.self) private var account
    @Environment(HistoricalHealthSamplesExportManager.self) private var historicalDataExportMgr
    @Environment(ManagedFileUpload.self) private var managedFileUpload
    @Environment(SensorKitDataFetcher.self) private var sensorKitDataFetcher
    // swiftlint:enable attributes
    
    @State private var isInSetup = false
    @State private var isPresentingFeedbackSheet = false
    
    @AccountFeatureFlagQuery(.isDebugModeEnabled)
    private var debugModeEnabled
    
    @SensorAccessPermissions private var sensorAccessPermissions
    @StudyManagerQuery private var enrollments: [StudyEnrollment]
    
    var body: some View {
        NavigationStack {
            ZStack {
                if account.signedIn && !isInSetup {
                    AccountOverview(
                        close: .showCloseButton,
                        deletion: .inEditMode(.custom(labels: .withdrawFromStudy) {
                            try await withdrawFromStudy()
                        })
                    ) {
                        accountSheetExtraContent
                    }
                } else {
                    AccountSetup { _ in
                        if dismissAfterSignIn {
                            dismiss() // we just signed in, dismiss the account setup sheet
                        }
                    } header: {
                        AccountSetupHeader()
                    }
                    .onAppear {
                        isInSetup = true
                    }
                }
            }
            .sheet(isPresented: $isPresentingFeedbackSheet) {
                NavigationStack {
                    FeedbackForm()
                }
            }
        }
    }
    
    @ViewBuilder private var accountSheetExtraContent: some View {
        PromptedActionsDigest(includeRejected: true)
        if let enrollment = enrollments.first {
            Section("Study Participation") {
                studyParticipationSection(enrollment)
            }
            Section {
                dataProcessingRow
            }
        }
        Section {
            Button {
                openSettingsApp()
            } label: {
                Label("Change Language", systemSymbol: .globe)
            }
            Button {
                isPresentingFeedbackSheet = true
            } label: {
                Label("Send Feedback", systemSymbol: .textBubble)
            }
        }
        Section {
            AboutRow()
            Link2(MyHeartCounts.website(.privacyPolicy)) {
                Label("Privacy Policy", systemSymbol: .lockShield)
                    .foregroundStyle(.textLabel)
            }
            NavigationLink {
                ContributionsList(projectLicense: .mit)
            } label: {
                Label("License Information", systemSymbol: .buildingColumns)
                    .foregroundStyle(.textLabel)
            }
            if debugModeEnabled || FeatureFlags.isTakingDemoScreenshots {
                NavigationLink {
                    DebugForm()
                } label: {
                    Label("Debug", systemSymbol: .wrenchAdjustable)
                        .foregroundStyle(.textLabel)
                }
            }
        }
    }
    
    private var isProcessingHealthData: Bool {
        let uploadCategories = [ManagedFileUpload.Category.liveHealthUpload, .historicalHealthUpload]
        return historicalDataExportMgr.session.map { $0.state == .running || $0.state == .paused } ?? false
            || uploadCategories.contains(where: { managedFileUpload.isActive($0) })
    }
    
    private var isProcessingSensorKitData: Bool {
        managedFileUpload.progressByCategory.keys.contains { $0.id.contains("SensorKit") }
            || !sensorKitDataFetcher.activeActivities.isEmpty
    }
    
    @ViewBuilder private var dataProcessingRow: some View {
        if let text = { () -> LocalizedStringResource? in
            switch (isProcessingHealthData, isProcessingSensorKitData) {
            case (true, true):
                "Processing Health and SensorKit Data…"
            case (true, false):
                "Processing Health Data…"
            case (false, true):
                "Processing SensorKit Data…"
            case (false, false):
                nil
            }
        }() {
            let label = HStack {
                Text(text)
                Spacer()
                ProgressView()
            }
            if debugModeEnabled {
                NavigationLink {
                    DataProcessingDebugView()
                } label: {
                    label
                }
            } else {
                label
            }
        }
    }
    
    init(dismissAfterSignIn: Bool = true) {
        self.dismissAfterSignIn = dismissAfterSignIn
    }
    
    
    @ViewBuilder
    private func studyParticipationSection(_ enrollment: StudyEnrollment) -> some View {
        Link2(MyHeartCounts.website(.homepage)) {
            HStack {
                makeEnrolledStudyRow(for: enrollment)
                Spacer()
                DisclosureIndicator()
            }
            .contentShape(Rectangle())
            .foregroundStyle(.textLabel)
        }
        PostTrialNudgesToggle()
        NavigationLink("Review Consent Forms") {
            SignedConsentForms()
        }
        if SensorKit.isAvailable && !sensorAccessPermissions.isFullyUndetermined {
            SensorKitButton() // TODO make this more lean!
        }
    }
    
    @ViewBuilder
    private func makeEnrolledStudyRow(for enrollment: StudyEnrollment) -> some View {
        if let studyInfo = enrollment.studyBundle?.studyDefinition.metadata {
            VStack(alignment: .leading) {
                Text(studyInfo.title)
                    .font(.headline)
                Text(studyInfo.shortExplanationText)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                Text("Enrolled since: \(enrollment.enrollmentDate, format: .dateTime)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("Study not available")
                .foregroundStyle(.secondary)
        }
    }
    
    private func withdrawFromStudy() async throws {
        _ = try await Functions.functions()
            .httpsCallable("markAccountForStudyWithdrawal")
            .call([:])
        try await account.accountService.logout()
    }
}


extension AccountSheet {
    private struct PostTrialNudgesToggle: View {
        @Environment(Account.self)
        private var account
        
        @State private var value = false
        @State private var updateTask: Task<Void, Never>?
        @State private var shouldHandleUpdates = true
        
        var body: some View {
            Toggle(isOn: $value) {
                VStack(alignment: .leading) {
                    Text("POST_TRIAL_ACTIVITY_NUDGES_TOGGLE_TITLE")
                    Text("POST_TRIAL_ACTIVITY_NUDGES_TOGGLE_SUBTITLE")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .onChange(of: account.details?.postTrialNudgesOptIn ?? false, initial: true) { _, newValue in
                shouldHandleUpdates = false
                value = newValue
                shouldHandleUpdates = true
            }
            .onChange(of: value) { _, newValue in
                updateTask?.cancel()
                guard shouldHandleUpdates else {
                    return
                }
                updateTask = Task {
                    do {
                        try await Task.sleep(for: .seconds(0.25))
                        var details = AccountDetails()
                        details.postTrialNudgesOptIn = newValue
                        try await account.accountService.updateAccountDetails(AccountModifications(modifiedDetails: details))
                    } catch {
                        // we silently ignore the error here
                    }
                }
            }
        }
    }
}

extension AccountSheet {
    private struct AboutRow: View {
        // swiftlint:disable attributes
        @Environment(Account.self) private var account
        // swiftlint:enable attributes
        @StudyManagerQuery private var enrollments: [StudyEnrollment]
        
        @State private var showExtendedInfo = false
        
        var body: some View {
            LabeledContent {
                let bundle = Bundle.main
                Text(bundle.appVersion)
            } label: {
                Label("My Heart Counts", systemSymbol: .infoCircle)
                    .foregroundStyle(.textLabel)
            }
            .onTapGesture(count: 5) {
                showExtendedInfo = true
            }
            .sheet(isPresented: $showExtendedInfo) {
                NavigationStack {
                    Form {
                        Section {
                            let bundle = Bundle.main
                            LabeledContent("Version" as String, value: bundle.appVersion)
                            LabeledContent("Build" as String, value: bundle.appBuildNumber?.description ?? "n/a")
                        }
                        Section {
                            LabeledContent("Study Revision" as String, value: enrollments.first?.studyRevision.description ?? "n/a")
                        }
                        Section {
                            LabeledContent("Project ID" as String, value: FirebaseApp.app()?.options.projectID ?? "n/a")
                            LabeledContent("Account ID" as String, value: account.details?.accountId ?? "n/a")
                        }
                    }
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            DismissButton()
                        }
                    }
                }
                .presentationDetents([.medium])
            }
        }
    }
}

extension AccountOverviewOperationLabels {
    fileprivate static let withdrawFromStudy = Self(
        formButton: "Withdraw from Study",
        confirmationAlertTitle: "Withdraw from Study",
        confirmationAlertMessage: "Are you sure you want to withdraw from the My Heart Counts study?\nYou can re-enroll later if you choose.",
        confirmationAlertSubmitButton: "Withdraw"
    )
}
