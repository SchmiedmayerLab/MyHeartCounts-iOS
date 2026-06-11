//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

// swiftlint:disable attributes

import OSLog
import SFSafeSymbols
import SpeziHealthKit
import SpeziOnboarding
import SpeziStudyDefinition
import SpeziViews
import SwiftUI


struct HealthRecords: View {
    /// Whether the Onboarding flow should include a Health Records step
    static let includeInOnboarding = false
    
    static let symbol: SFSymbol = if #available(iOS 18.1, *) {
        .waveformPathEcgTextPage
    } else {
        .heartTextSquare
    }
    
    private let title: LocalizedStringResource = "Health Records"
    
    @Environment(StudyBundleLoader.self) private var studyLoader
    @Environment(ManagedNavigationStack.Path.self) private var path
    @Environment(ClinicalRecordPermissions.self) private var clinicalRecordPermissions
    
    @State private var viewState: ViewState = .idle
    @State private var isShowingLearnMoreText = false
    
    var body: some View {
        OnboardingPage(symbol: Self.symbol, title: title, description: "HEALTH_RECORDS_PERMISSIONS_SUBTITLE") {
            EmptyView()
        } footer: {
            OnboardingActionsView(
                primaryTitle: "Review Permissions",
                primaryViewState: $viewState,
                primaryAction: {
                    await grantAccess()
                },
                secondaryTitle: "Learn More",
                secondaryAction: {
                    isShowingLearnMoreText.toggle()
                }
            )
        }
        .sheet(isPresented: $isShowingLearnMoreText) {
            OnboardingLearnMore(
                title: title,
                learnMoreText: "HEALTH_RECORDS_PERMISSIONS_DESCRIPTION"
            )
        }
        .navigationBarBackButtonHidden(viewState != .idle)
    }
    
    
    private func grantAccess() async {
        do {
            try await clinicalRecordPermissions.askForAuthorization(askAgainIfCancelledPreviously: true)
        } catch {
            logger.error("Error requesting access to health records: \(error)")
        }
        path.nextStep()
    }
}
