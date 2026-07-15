//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import FirebaseMessaging
import Foundation
import MyHeartCountsShared
import OSLog
import Spezi
import SpeziAccount
import SpeziFoundation
import SpeziNotifications
import enum UIKit.UIBackgroundFetchResult


@Observable
@MainActor
final class NotificationsManager: NSObject, Module, EnvironmentAccessible, Sendable {
    struct RemoteNotificationsToken: Sendable {
        let apns: Data?
        let fcm: String?
    }
    
    // swiftlint:disable attributes
    @ObservationIgnored @Application(\.logger)
    private var logger
    @ObservationIgnored @Dependency(Notifications.self)
    private var notifications
    @ObservationIgnored @Application(\.registerRemoteNotifications)
    private var registerRemoteNotifications
    @ObservationIgnored @Dependency(Account.self)
    private var account: Account?
    // swiftlint:enable attributes
    
    private(set) var isAuthorized = false
    
    private(set) var remoteNotificationsToken: RemoteNotificationsToken?
    
    
    func configure() {
        guard LocalPreferencesStore.standard[.onboardingFlowComplete] else {
            return
        }
        Task {
            try await setup()
        }
    }
    
    func requestNotificationPermissions() async throws {
        _ = try await notifications.requestNotificationAuthorization(options: [.alert, .badge, .sound, .providesAppNotificationSettings])
        try await _setup(requestPermissionsIfNotDetermined: false)
    }
    
    func setup() async throws {
        try await _setup(requestPermissionsIfNotDetermined: true)
    }
    
    private func _setup(requestPermissionsIfNotDetermined: Bool) async throws {
        let settings = await notifications.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            isAuthorized = true
            if !(ProcessInfo.isBeingUITested || ProcessInfo.isRunningInXCTest) {
                do {
                    try await registerRemoteNotifications()
                } catch {
                    logger.error("Unable to register for remote notifications: \(error)")
                }
            }
        case .denied:
            isAuthorized = false
        case .notDetermined:
            if requestPermissionsIfNotDetermined {
                // shouldn't really end up here since we request notification permissions as part of the onboarding,
                // but we'll simply trigger it again, just in case.
                try await requestNotificationPermissions()
            }
        @unknown default:
            isAuthorized = false
        }
    }
}


extension NotificationsManager: NotificationHandler {
    func handleNotificationAction(_ response: UNNotificationResponse) async {}
    
    func receiveIncomingNotification(_ notification: UNNotification) async -> UNNotificationPresentationOptions? {
        [.badge, .badge, .list, .sound]
    }
    
    func receiveRemoteNotification(_ remoteNotification: [AnyHashable: Any]) async -> BackgroundFetchResult {
        .noData
    }
}


extension NotificationsManager: NotificationTokenHandler {
    func receiveUpdatedDeviceToken(_ deviceToken: Data) {
        Task {
            let messaging = Messaging.messaging()
            messaging.apnsToken = deviceToken
            guard let fcmToken = try? await messaging.token() else {
                return
            }
            try await setFCMToken(fcmToken)
        }
    }
    
    func setFCMToken(_ newToken: String?) async throws {
        guard let account else {
            return
        }
        // since these updates typically happen very early into the launch of the app, the account details
        // might not be fully populated & available yet; we need to wait until they are available in order
        // to work around https://github.com/SchmiedmayerLab/MyHeartCounts-iOS/issues/169
        await account.waitForAccountDetailsReady()
        var updatedDetails = AccountDetails()
        var removedDetails = AccountDetails()
        switch (account.details?.fcmToken, newToken) {
        case (.none, .none):
            return
        case (_, .some(let newToken)):
            updatedDetails.fcmToken = newToken
        case (.some(let oldToken), .none):
            removedDetails.fcmToken = oldToken
        }
        try await account.accountService.updateAccountDetails(.init(modifiedDetails: updatedDetails, removedAccountDetails: removedDetails))
    }
}
