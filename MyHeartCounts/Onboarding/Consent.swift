//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Grove
import GroveAccount
import GroveConsent
import GroveFoundation
import GroveOnboarding
import GroveStudy
import GroveViews
import OSLog
import SwiftUI


struct Consent: View {
    // swiftlint:disable attributes
    @Environment(ManagedNavigationStack.Path.self) private var path
    @Environment(OnboardingDataCollection.self) private var onboardingData: OnboardingDataCollection?
    @Environment(MyHeartCountsStandard.self) private var standard
    @Environment(Account.self) private var account
    // NOTE: at this step, we aren't yet enrolled into the study,
    // so we can't access `studyManager.enrollments`, but we CAN access
    // `studyManager.preferredLocale`, since that has been set in a previous step.
    @Environment(StudyManager.self) private var studyManager
    // swiftlint:enable attributes
    
    private let document: ConsentDocument
    private let continueAction: (@MainActor () -> Void)?
    @State private var viewState: ViewState = .idle
    
    var body: some View {
        OnboardingConsentView(consentDocument: document, title: nil, viewState: $viewState) {
            onboardingData?.consentResponses = document.userResponses
            let result = try document.export(using: pdfExportConfig)
            try await standard.uploadConsentDocument(result)
            do {
                var accountDetailUpdates = AccountDetails()
                accountDetailUpdates.lastSignedConsentDate = .now
                accountDetailUpdates.lastSignedConsentVersion = document.metadata.version?.description
                accountDetailUpdates.futureStudies = document.userResponses.toggleValue(for: .futureStudiesOptIn) == true
                accountDetailUpdates.didOptInToTrial = document.userResponses.selectedOption(for: .trialOptIn) == .trialYes
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
                    consentDocument: document,
                    exportConfiguration: pdfExportConfig,
                    viewState: $viewState
                )
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
    init(document: ConsentDocument, continueAction: (@MainActor () -> Void)? = nil) {
        self.document = document
        self.continueAction = continueAction
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


#if DEBUG
#Preview {
    ManagedNavigationStack {
        Consent(document: .previewDoc)
    }
    .environment(StudyBundleLoader.shared)
    .environment(OnboardingDataCollection())
    .previewWith(standard: MyHeartCountsStandard()) {
        ConsentManager()
        MyHeartCounts.previewModels
    }
}
#endif
