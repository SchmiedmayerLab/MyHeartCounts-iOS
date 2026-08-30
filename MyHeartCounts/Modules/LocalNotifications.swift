//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import Grove
import UserNotifications


/// Intended primarily (exclusively) for debugging purposes.
final class LocalNotifications: Module, EnvironmentAccessible, Sendable {
    func send(
        id: String = UUID().uuidString, // swiftlint:disable:this function_default_parameter_at_end
        title: String,
        body: String,
        level: UNNotificationInterruptionLevel = .active,
        date: Date? = nil
    ) async throws {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.interruptionLevel = level
        let trigger: UNNotificationTrigger?
        if let date {
            trigger = UNTimeIntervalNotificationTrigger(timeInterval: date.timeIntervalSinceNow, repeats: false)
        } else {
            trigger = nil
        }
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        try await UNUserNotificationCenter.current().add(request)
    }
    
    // periphery:ignore - API
    func removeDeliveredNotification(withId id: String) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
    }
}
