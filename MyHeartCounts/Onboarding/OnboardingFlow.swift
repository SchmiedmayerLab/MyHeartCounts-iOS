//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import SFSafeSymbols
import Spezi
@_spi(TestingSupport)
import SpeziAccount
import SpeziFirebaseAccount
import SpeziHealthKit
import SpeziNotifications
import SpeziOnboarding
import SpeziStudy
import SpeziViews
import SwiftUI


struct OnboardingSheet: View {
    @Binding var didComplete: Bool
    
    var body: some View {
        if !didComplete {
            Color.clear.frame(height: 0)
                .sheet(isPresented: !$didComplete) {
                    AppOnboardingFlow(didComplete: $didComplete)
                }
        }
    }
}


/// Displays a multi-step onboarding flow for the My Heart Counts iOS app
///
/// - Note: This is the general app onboarding flow, **not** the study-specific onboarding
private struct AppOnboardingFlow: View {
    @Environment(\.scenePhase)
    private var scenePhase
    @Environment(\.notificationSettings)
    private var notificationSettings
    
    @Binding var didComplete: Bool
    
    @State private var onboardingData = OnboardingDataCollection()
    @State private var localNotificationAuthorization = false
    
    
    var body: some View {
        ManagedNavigationStack(didComplete: $didComplete) { // swiftlint:disable:this closure_body_length
            Welcome()
                .onboardingStep(.welcome)
            EligibilityScreening()
                .onboardingStep(.eligibility)
            if !FeatureFlags.disableFirebase {
                AccountOnboarding()
                    .injectingSpezi()
                    .navigationBarBackButtonHidden()
                    .onboardingStep(.login)
            }
            OnboardingDisclaimerStep(
                icon: .textPageBadgeMagnifyingglass,
                title: "ONBOARDING_DISCLAIMER_1_TITLE",
                primaryText: "ONBOARDING_DISCLAIMER_1_PRIMARY_TEXT",
                learnMoreText: "ONBOARDING_DISCLAIMER_1_LEARN_MORE_TEXT"
            )
                .onboardingStep(.disclaimer1)
                .injectingSpezi()
                // we hide the back button here, to prevent the user from returning to the "re-activate account" page
                // (in case that's presented), since that yes/no decision should only be made once.
                .navigationBarBackButtonHidden()
            OnboardingDisclaimerStep(
                icon: .figureWalkMotion,
                title: "ONBOARDING_DISCLAIMER_2_TITLE",
                primaryText: "ONBOARDING_DISCLAIMER_2_PRIMARY_TEXT",
                learnMoreText: "ONBOARDING_DISCLAIMER_2_LEARN_MORE_TEXT"
            )
                .onboardingStep(.disclaimer2)
                .injectingSpezi()
            OnboardingDisclaimerStep(
                icon: .lockSquareStack,
                title: "ONBOARDING_DISCLAIMER_3_TITLE",
                primaryText: "ONBOARDING_DISCLAIMER_3_PRIMARY_TEXT",
                learnMoreText: "ONBOARDING_DISCLAIMER_3_LEARN_MORE_TEXT"
            )
                .onboardingStep(.disclaimer3)
                .injectingSpezi()
            OnboardingDisclaimerStep(
                icon: .documentOnClipboard,
                title: "ONBOARDING_DISCLAIMER_4_TITLE",
                primaryText: "ONBOARDING_DISCLAIMER_4_PRIMARY_TEXT",
                learnMoreText: "ONBOARDING_DISCLAIMER_4_LEARN_MORE_TEXT"
            )
                .onboardingStep(.disclaimer4)
                .injectingSpezi()
            ComprehensionScreening()
                .onboardingStep(.comprehension)
                .injectingSpezi()
            #if !(targetEnvironment(simulator) && (arch(i386) || arch(x86_64)))
            Consent()
                .onboardingStep(.consent)
                .injectingSpezi()
                .navigationStepIdentifier("Consent")
            #endif
            if HKHealthStore.isHealthDataAvailable() {
                // IDEA instead of having this in an if, we should probably have a full-screen "you can't participate" thing if the user doesn't have HealthKit?
                HealthKitPermissions()
                    .onboardingStep(.healthAccess)
                    .injectingSpezi()
                if ClinicalRecordPermissions.isAvailable && HealthRecords.includeInOnboarding {
                    HealthRecords()
                        .onboardingStep(.healthRecords)
                        .injectingSpezi()
                }
            }
            WorkoutPreferenceSetting()
                .onboardingStep(.workoutPreference)
                .injectingSpezi()
            if !localNotificationAuthorization {
                NotificationPermissions()
                    .onboardingStep(.notifications)
                    .injectingSpezi()
            }
            DemographicsStep()
                .onboardingStep(.demographics)
                .injectingSpezi()
            FinalEnrollmentStep()
                .onboardingStep(.finalStep)
                .injectingSpezi()
        }
        .environment(\.isInOnboardingFlow, true)
        .environment(onboardingData)
        .interactiveDismissDisabled(!didComplete)
        .onChange(of: scenePhase, initial: true) {
            guard case .active = scenePhase else {
                return
            }
            Task {
                localNotificationAuthorization = await notificationSettings().authorizationStatus == .authorized
            }
        }
    }
}


extension OnboardingStep {
    static let welcome = Self(rawValue: "welcome")
    static let eligibility = Self(rawValue: "eligibility")
    static let login = Self(rawValue: "login")
    static let disclaimer1 = Self(rawValue: "disclaimer1")
    static let disclaimer2 = Self(rawValue: "disclaimer2")
    static let disclaimer3 = Self(rawValue: "disclaimer3")
    static let disclaimer4 = Self(rawValue: "disclaimer4")
    static let comprehension = Self(rawValue: "comprehension")
    static let consent = Self(rawValue: "consent")
    static let healthAccess = Self(rawValue: "healthAccess")
    static let healthRecords = Self(rawValue: "healthRecords")
    static let workoutPreference = Self(rawValue: "workoutPreference")
    static let notifications = Self(rawValue: "notifications")
    static let demographics = Self(rawValue: "demographics")
    static let finalStep = Self(rawValue: "finalStep")
}
