//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import MyHeartCountsShared
import OSLog
import Spezi
import SpeziFoundation
import SwiftUI


// intentionally a global variable
let logger = Logger(category: .init(""))


@main
struct MyHeartCounts: App {
    static let appId = 972189947
    
    @UIApplicationDelegateAdaptor(MyHeartCountsDelegate.self)
    private var appDelegate
    
    @LocalPreference(.onboardingFlowComplete)
    private var didCompleteOnboarding
    
    var body: some Scene {
        WindowGroup {
            RootView()
                .spezi(appDelegate)
            OnboardingSheet(didComplete: $didCompleteOnboarding)
        }
        .environment(StudyBundleLoader.shared)
        .environment(appDelegate)
    }
    
    init() {
        print(CommandLine.arguments)
        // This needs to run before *any* Spezi-related code is executed,
        // i.e. before the AppDelegate's `willFinishLaunchingWithOptions`
        // method gets called. Hence why we put it in here.
        let prefs = LocalPreferencesStore.standard
        if LaunchOptions.launchOptions[.setupTestEnvironment].resetExistingData {
            prefs[.lastUsedFirebaseConfig] = nil
            prefs[.onboardingFlowComplete] = false
        }
        if LaunchOptions.launchOptions[.setupTestEnvironment].loginAndEnroll {
            prefs[.onboardingFlowComplete] = true
        }
    }
}
