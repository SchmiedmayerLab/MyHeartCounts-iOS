//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import Grove
import GroveNotifications
import SwiftUI
import UserNotifications


struct NotificationsManagerControlView: View {
    @Environment(NotificationsManager.self)
    private var notificationsManager
    
    @Environment(\.notificationSettings)
    private var _getNotificationSettings
    
    @State private var notificationSettings: UNNotificationSettings?
    
    var body: some View {
        Form {
            Section("Local Notifications Status" as String) {
                LabeledContent("AuthorizationStatus" as String, value: notificationSettings?.authorizationStatus.description ?? "n/a")
                if let notificationSettings {
                    row(title: "sound", forSetting: notificationSettings.soundSetting)
                    row(title: "badge", forSetting: notificationSettings.badgeSetting)
                    row(title: "alert", forSetting: notificationSettings.alertSetting)
                    row(title: "notificationCenter", forSetting: notificationSettings.notificationCenterSetting)
                    row(title: "lockScreen", forSetting: notificationSettings.lockScreenSetting)
                    row(title: "carPlay", forSetting: notificationSettings.carPlaySetting)
                }
            }
            Section("Remote Notifications Registration" as String) {
                tokenRow(
                    "APNS Token",
                    value: notificationsManager.remoteNotificationsToken?.apns.map { $0.map { String($0) }.joined(separator: " ") }
                )
                tokenRow(
                    "FCM Token",
                    value: notificationsManager.remoteNotificationsToken?.fcm
                )
            }
        }
        .onAppear {
            update()
        }
        .refreshable {
            update()
        }
    }
    
    
    private func update() {
        Task {
            notificationSettings = await _getNotificationSettings()
        }
    }
    
    @ViewBuilder
    private func tokenRow(_ title: String, value: String?) -> some View {
        let label = HStack {
            Text(title)
                .foregroundStyle(.primary)
            Spacer()
            Text(value ?? "n/a")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
        if let value {
            Button {
                UIPasteboard.general.string = value
            } label: {
                label
            }
        } else {
            label
        }
    }
    
    @ViewBuilder
    private func row(title: String, forSetting setting: UNNotificationSetting) -> some View {
        let value = switch setting {
        case .enabled: "enabled"
        case .disabled: "disabled"
        case .notSupported: "not supported"
        @unknown default: "unknown(\(setting.rawValue))"
        }
        LabeledContent(title, value: value)
    }
}
