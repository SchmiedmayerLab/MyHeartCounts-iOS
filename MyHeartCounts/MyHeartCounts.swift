//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Grove
import GroveFoundation
import MyHeartCountsShared
import OSLog
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
                .grove(appDelegate)
            OnboardingSheet(didComplete: $didCompleteOnboarding)
        }
        .environment(StudyBundleLoader.shared)
        .environment(appDelegate)
    }
    
    init() {
        print(CommandLine.arguments)
        // This needs to run before *any* Grove-related code is executed,
        // i.e. before the AppDelegate's `willFinishLaunchingWithOptions`
        // method gets called. Hence why we put it in here.
        //
        // The early reset deletes all locally persisted state (SwiftData stores, LocalStorage, staged
        // uploads, the Firebase Auth keychain session). It has to happen here rather than in
        // SetupTestEnvironment.configure(): modules act on their persisted state as soon as they are
        // configured, and SetupTestEnvironment's own reset runs behind `Grove.loadFirebase` + a 1s sleep,
        // by which point StudyManager has already requested HealthKit authorization for a stale enrollment.
        SetupTestEnvironment.performEarlyResetIfNeeded()
        let prefs = LocalPreferencesStore.standard
        if LaunchOptions.launchOptions[.setupTestEnvironment].resetExistingData {
            prefs[.lastUsedFirebaseConfig] = nil
            prefs[.onboardingFlowComplete] = false
        }
        switch LaunchOptions.launchOptions[.setupTestEnvironment].loginAndEnroll {
        case .skip:
            break
        case .enable:
            prefs[.onboardingFlowComplete] = true
        }
    }
}
