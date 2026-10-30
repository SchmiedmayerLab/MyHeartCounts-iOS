//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Grove
@_spi(TestingSupport)
import GroveAccount
import GroveFirebaseAccount
import GroveHealthKit
import GroveNotifications
import GroveOnboarding
import GroveStudy
import GroveViews
import SFSafeSymbols
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
        ManagedNavigationStack(didComplete: $didComplete) {
            Welcome()
                .onboardingStep(.welcome)
            EligibilityScreening()
                .onboardingStep(.eligibility)
            if !FeatureFlags.disableFirebase {
                AccountOnboarding()
                    .injectingGrove()
                    .navigationBarBackButtonHidden()
                    .onboardingStep(.login)
                // the `AccountOnboarding` step will, as needed, branch into the consent flow.
            }
            if HKHealthStore.isHealthDataAvailable() {
                // IDEA instead of having this in an if, we should probably have a full-screen "you can't participate" thing if the user doesn't have HealthKit?
                HealthKitPermissions()
                    .onboardingStep(.healthAccess)
                    .injectingGrove()
                    // we don't want the user to be able to return to the Consent flow
                    .navigationBarBackButtonHidden()
                if ClinicalRecordPermissions.isAvailable && HealthRecordPermissions.includeInOnboarding {
                    HealthRecordPermissions()
                        .onboardingStep(.healthRecords)
                        .injectingGrove()
                }
            }
            WorkoutPreferenceSetting()
                .onboardingStep(.workoutPreference)
                .injectingGrove()
            if !localNotificationAuthorization {
                NotificationPermissions()
                    .onboardingStep(.notifications)
                    .injectingGrove()
            }
            DemographicsStep()
                .onboardingStep(.demographics)
                .injectingGrove()
            FinalEnrollmentStep()
                .onboardingStep(.finalStep)
                .injectingGrove()
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
