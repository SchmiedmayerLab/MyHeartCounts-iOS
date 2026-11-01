//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2023 Stanford University
//
// SPDX-License-Identifier: MIT
//

import FirebaseCore
import FirebaseFunctions
import GroveAccount
import GroveConsent
import GroveHealthKitBulkExport
import GroveLicense
import GroveSensorKit
import GroveStudy
import GroveViews
import MHCStudyDefinition
import MyHeartCountsShared
import SFSafeSymbols
import SwiftUI


struct AccountSheet: View {
    private let dismissAfterSignIn: Bool
    // swiftlint:disable attributes
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettingsApp) private var openSettingsApp
    @Environment(Account.self) private var account
    @Environment(ConsentManager.self) private var consentManager: ConsentManager?
    @Environment(HistoricalHealthSamplesExportManager.self) private var historicalDataExportMgr
    @Environment(ManagedFileUpload.self) private var managedFileUpload
    @Environment(SensorKitDataFetcher.self) private var sensorKitDataFetcher
    @Environment(StudyManager.self) private var studyManager
    // swiftlint:enable attributes
    
    @State private var isInSetup = false
    @State private var isPresentingFeedbackSheet = false
    @State private var withdrawalSigning: WithdrawalSigningRequest?
    
    @AccountFeatureFlagQuery(.isDebugModeEnabled)
    private var debugModeEnabled
    
    @SensorAccessPermissions private var sensorAccessPermissions
    @StudyManagerQuery private var enrollments: [StudyEnrollment]
    
    var body: some View {
        NavigationStack {
            ZStack {
                if account.signedIn && !isInSetup {
                    accountOverview
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
            .sheet(item: $withdrawalSigning) { request in
                WithdrawalForm(document: request.document) {
                    request.finish(didSign: true)
                }
                .onDisappear {
                    // dismissing the form without signing it cancels the withdrawal
                    request.finish(didSign: false)
                }
            }
        }
        .accessibilityIdentifier("MHC:AccountSheet")
    }
    
    private var accountOverview: some View {
        AccountOverview(
            close: .showCloseButton,
            deletion: showsWithdrawalBelowLogout
                ? .belowLogout(.custom(labels: .withdrawFromStudy) {
                    try await withdrawFromStudy()
                })
                : .inEditMode(.custom(labels: .withdrawFromStudy) {
                    try await withdrawFromStudy()
                })
        ) {
            accountSheetExtraContent
        }
    }
    
    @ViewBuilder private var accountSheetExtraContent: some View {
        if let enrollment = enrollments.first {
            PromptedActionsDigest(context: .viewAll)
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
                ContributionsList(
                    projectLicense: .mit,
                    projectUrl: "https://github.com/SchmiedmayerLab/MyHeartCounts-iOS/"
                )
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
    
    /// Imperial participants found "Withdraw from Study" hard to discover behind "Edit", so their account sheet lists it below "Log Out".
    private var showsWithdrawalBelowLogout: Bool {
        switch StudyVariant.current {
        case .stanford: false
        case .imperial: true
        }
    }
    
    private var isProcessingHealthData: Bool {
        let uploadCategories = [ManagedFileUpload.Category.liveHealthUpload, .historicalHealthUpload]
        return historicalDataExportMgr.session?.state == .running
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
        NavigationLink("View Participation Stats") {
            ParticipationStatsView(enrollment: enrollment)
        }
        PostTrialNudgesToggle()
        UpdateComorbiditiesButton()
        NavigationLink("Review Consent Forms") {
            SignedConsentForms()
        }
        if SensorKit.isAvailable && !sensorAccessPermissions.isFullyUndetermined {
            // if the SensorKit auth is fully undetermined (i.e., the user hasn't authorized any sensors),
            // we skip this button, since in that case the prompted action above will kick in.
            SensorKitButton()
        }
    }
    
    @ViewBuilder
    private func makeEnrolledStudyRow(for enrollment: StudyEnrollment) -> some View {
        if let studyInfo = enrollment.studyBundle?.studyDefinition.metadata {
            let locale = LocalizationKey(locale: studyManager.preferredLocale) ?? .enUS
            VStack(alignment: .leading) {
                if let title = studyInfo.title[locale] {
                    Text(title)
                        .font(.headline)
                }
                if let explainer = studyInfo.shortExplanationText[locale] {
                    Text(explainer)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.secondary)
                }
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
        if let withdrawalForm = consentManager?.loadWithdrawalForm() {
            // the study requires a signed record of the withdrawal, which is kept with the participant's consent forms.
            let didSign = await withCheckedContinuation { continuation in
                withdrawalSigning = WithdrawalSigningRequest(document: withdrawalForm, continuation: continuation)
            }
            guard didSign else {
                throw CancellationError()
            }
        }
        _ = try await Functions.functions()
            .httpsCallable("markAccountForStudyWithdrawal")
            .call([:])
        try await account.accountService.logout()
    }
}


extension AccountSheet {
    /// A pending request for the participant to sign the study's withdrawal form, which the withdrawal waits for.
    @MainActor
    private final class WithdrawalSigningRequest: Identifiable {
        let document: ConsentDocument
        private var continuation: CheckedContinuation<Bool, Never>?
        
        init(document: ConsentDocument, continuation: CheckedContinuation<Bool, Never>) {
            self.document = document
            self.continuation = continuation
        }
        
        /// Resumes the waiting withdrawal; calls after the first one have no effect.
        func finish(didSign: Bool) {
            continuation?.resume(returning: didSign)
            continuation = nil
        }
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
        @Environment(StudyBundleLoader.self) private var studyBundleLoader
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
            .accessibilityElement()
            .accessibilityIdentifier("MHC:AboutRow")
            .sheet(isPresented: $showExtendedInfo) {
                NavigationStack {
                    Form {
                        Section {
                            let bundle = Bundle.main
                            LabeledContent("Version" as String, value: bundle.appVersion)
                            LabeledContent("Build" as String, value: bundle.appBuildNumber?.description ?? "n/a")
                        }
                        Section {
                            LabeledContent("Project ID" as String, value: FirebaseApp.app()?.options.projectID ?? "n/a")
                            LabeledContent("Account ID" as String, value: account.details?.accountId ?? "n/a")
                            LabeledContent("Study Variant" as String, value: DeferredConfigLoading.activeStudyVariant?.rawValue ?? "n/a")
                            LabeledContent("Study Backend" as String, value: DeferredConfigLoading.activeFirebaseConfig?.description ?? "n/a")
                        }
                        Section {
                            LabeledContent("Study Revision (enrolled)" as String, value: enrollments.first?.studyRevision.description ?? "n/a")
                            LabeledContent(
                                "Study Revision (fetched)" as String,
                                value: (try? studyBundleLoader.studyBundle?.get())?.studyDefinition.studyRevision.description ?? "n/a"
                            )
                            LabeledContent(
                                "lastSignedConsentVersion" as String,
                                value: account.details?.lastSignedConsentVersion?.description ?? "n/a"
                            )
                        }
                    }
                    .navigationTitle("Extended Info" as String)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            DismissButton()
                        }
                    }
                }
                .presentationDetents([.medium, .large])
                .accessibilityIdentifier("MHC:AboutRow:ExtendedInfoSheet")
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
