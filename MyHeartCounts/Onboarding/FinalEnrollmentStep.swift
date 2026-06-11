//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import SFSafeSymbols
import Spezi
import SpeziAccount
import SpeziConsent
import SpeziFoundation
import SpeziHealthKitBulkExport
import SpeziLocalStorage
import SpeziNotifications
import SpeziOnboarding
import SpeziStudy
import SpeziViews
import SwiftUI


struct FinalEnrollmentStep: View {
    // swiftlint:disable attributes
    @Environment(ManagedNavigationStack.Path.self) private var path
    @Environment(MyHeartCountsStandard.self) private var standard
    @Environment(OnboardingDataCollection.self) private var onboardingData
    @Environment(StudyBundleLoader.self) private var studyLoader
    // swiftlint:enable attributes
    
    @State private var viewState: ViewState = .idle
    
    
    private var showTrialSection: Bool {
        onboardingData.trialOptInState == .optedIn
    }
    
    var body: some View {
        OnboardingPage(title: "Welcome to My Heart Counts", description: "What happens next:") {
            content
        } footer: {
            OnboardingActionsView("Start", viewState: $viewState) {
                try await completeStudyEnrollment()
            }
        }
        .navigationBarBackButtonHidden(viewState != .idle)
    }
    
    @ViewBuilder private var content: some View {
        Grid(horizontalSpacing: 16, verticalSpacing: 16) {
            let calendarSymbol = if #available(iOS 26, *) {
                SFSymbol._7Calendar
            } else {
                SFSymbol.calendar
            }
            OnboardingIconGridRow(
                icon: calendarSymbol,
                text: "FINAL_ENROLLMENT_STEP_MESSAGE_SEVEN_DAYS"
            )
            OnboardingIconGridRow(
                icon: .deskclock,
                text: "FINAL_ENROLLMENT_STEP_MESSAGE_EVERY_DAY"
            )
            OnboardingIconGridRow(
                icon: .chartLineTextClipboard,
                text: "FINAL_ENROLLMENT_STEP_MESSAGE_DATA_COLLECTION"
            )
            if showTrialSection {
                OnboardingIconGridRow(
                    icon: .calendarBadgeClock,
                    text: "FINAL_ENROLLMENT_STEP_MESSAGE_BASELINE"
                )
            }
            OnboardingIconGridRow(
                icon: .arrowUpHeart,
                text: "FINAL_ENROLLMENT_STEP_MESSAGE_FOOTER"
            )
        }
        .padding(.leading)
    }
    
    
    private func completeStudyEnrollment() async throws {
        guard let study = try? studyLoader.studyBundle?.get() else {
            // guaranteed to be non-nil if we end up in this view
            return
        }
        try await standard.enroll(in: study)
        path.nextStep()
    }
}


#Preview {
    ManagedNavigationStack {
        FinalEnrollmentStep()
    }
    .environment(OnboardingDataCollection())
    .environment(StudyBundleLoader.shared)
    .previewWith(standard: MyHeartCountsStandard()) {
        MyHeartCounts.previewModels
        HistoricalHealthSamplesExportManager()
        BulkHealthExporter()
    }
}
