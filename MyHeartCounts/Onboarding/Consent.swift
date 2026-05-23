//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import OSLog
import Spezi
import SpeziAccount
import SpeziConsent
import SpeziFoundation
import SpeziOnboarding
import SpeziStudy
import SpeziViews
import SwiftUI


struct Consent: View {
    // swiftlint:disable attributes
    @Environment(ManagedNavigationStack.Path.self) private var path
    @Environment(OnboardingDataCollection.self) private var onboardingData: OnboardingDataCollection?
    @Environment(MyHeartCountsStandard.self) private var standard
    @Environment(Account.self) private var account
    @Environment(StudyBundleLoader.self) private var studyLoader
    // NOTE: at this step, we aren't yet enrolled into the study,
    // so we can't access `studyManager.enrollments`, but we CAN access
    // `studyManager.preferredLocale`, since that has been set in a previous step.
    @Environment(StudyManager.self) private var studyManager
    // swiftlint:enable attributes
    
    private let continueAction: (@MainActor () -> Void)?
    
    @State private var consentDocument: ConsentDocument?
    @State private var viewState: ViewState = .idle
    
    var body: some View {
        OnboardingConsentView(consentDocument: consentDocument, title: nil, viewState: $viewState) {
            guard let consentDocument else {
                return
            }
            onboardingData?.consentResponses = consentDocument.userResponses
            let result = try consentDocument.export(using: pdfExportConfig)
            try await standard.uploadConsentDocument(result)
            do {
                var accountDetailUpdates = AccountDetails()
                accountDetailUpdates.lastSignedConsentDate = .now
                accountDetailUpdates.lastSignedConsentVersion = consentDocument.metadata.version?.description
                accountDetailUpdates.futureStudies = consentDocument.userResponses.toggles["future-studies"] == true
                // swiftlint:disable:next line_length
                accountDetailUpdates.didOptInToTrial = consentDocument.userResponses.selects["short-term-physical-activity-trial"] == "short-term-physical-activity-trial-yes"
                let modifications = try AccountModifications(modifiedDetails: accountDetailUpdates)
                try await account.accountService.updateAccountDetails(modifications)
            }
            if let continueAction {
                continueAction()
            } else {
                path.nextStep()
            }
        }
        .navigationTitle("Consent")
        .navigationBarBackButtonHidden(viewState != .idle)
        .scrollIndicators(.visible)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ConsentShareButton(
                    consentDocument: consentDocument,
                    exportConfiguration: pdfExportConfig,
                    viewState: $viewState
                )
            }
        }
        .task {
            do {
                try await loadConsentDocument()
            } catch {
                logger.error("Failed to load/create ConsentDocument: \(error)")
            }
        }
    }
    
    private var pdfExportConfig: ConsentDocument.ExportConfiguration {
        ConsentDocument.ExportConfiguration(
            paperSize: studyManager.preferredLocale.preferredPaperSize
        )
    }
    
    /// - parameter continueAction: An action which should be performed when the user submits the consent, to continue in the flow.
    ///     Defaults to `nil`, in which case the `Consent` view will advance its `ManagedNavigationStack`.
    init(continueAction: (@MainActor () -> Void)? = nil) {
        self.continueAction = continueAction
    }
    
    private func loadConsentDocument() async throws {
        guard consentDocument == nil else {
            return
        }
        // NOTE: we need to get the StudyBundle from the StudyBundleLoader, instead of the StudyManager,
        // since the app won't necessarily be already enrolled at this point.
        // (it is if this is a Consent renewal, but not during the initial onboarding...)
        guard let studyBundle = try? studyLoader.studyBundle?.get(),
              let consentFileRef = studyBundle.studyDefinition.metadata.consentFileRef,
              let text = studyBundle.consentText(
                for: consentFileRef,
                in: studyManager.preferredLocale,
                using: .requirePerfectMatch,
                fallbackLocale: studyManager.defaultLanguageFallbackLocale
              ) else {
            return
        }
        consentDocument = try ConsentDocument(
            markdown: text,
            initialName: account.details?.name
        )
    }
}


extension Locale {
    fileprivate var preferredPaperSize: ConsentDocument.ExportConfiguration.PaperSize {
        switch self.region {
        case .unitedStates: .usLetter
        default: .dinA4
        }
    }
}


#Preview {
    ManagedNavigationStack {
        Consent()
    }
    .environment(StudyBundleLoader.shared)
    .environment(OnboardingDataCollection())
    .previewWith(standard: MyHeartCountsStandard()) {
        ConsentManager()
        MyHeartCounts.previewModels
    }
}
