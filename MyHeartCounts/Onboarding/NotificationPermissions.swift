//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Grove
import GroveOnboarding
import GroveViews
import OSLog
import SFSafeSymbols
import SwiftUI


struct NotificationPermissions: View {
    @Environment(ManagedNavigationStack.Path.self)
    private var onboardingPath
    @Environment(NotificationsManager.self)
    private var notificationsManager
    
    @State private var viewState: ViewState = .idle
    
    
    var body: some View {
        OnboardingPage(symbol: .bellBadge, title: "Notifications", description: "NOTIFICATION_PERMISSIONS_DESCRIPTION") {
            EmptyView()
        } footer: {
            OnboardingActionsView("Allow Notifications", viewState: $viewState) {
                await allowNotifications()
            }
        }
        .navigationBarBackButtonHidden(viewState != .idle)
        .accessibilityIdentifier("MHC:OnboardingStepNotifications")
    }
    
    
    private func allowNotifications() async {
        do {
            // Notification Authorization is not available in the preview simulator.
            if ProcessInfo.processInfo.isPreviewSimulator {
                try await _Concurrency.Task.sleep(for: .seconds(0.75))
            } else {
                try await notificationsManager.requestNotificationPermissions()
            }
        } catch {
            logger.error("Could not request notification permissions: \(error)")
        }
        onboardingPath.nextStep()
    }
}


#Preview {
    ManagedNavigationStack {
        NotificationPermissions()
    }
    .environment(StudyBundleLoader.shared)
    .previewWith(standard: MyHeartCountsStandard()) {
        NotificationsManager()
        MyHeartCounts.previewModels
    }
}
