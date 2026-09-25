//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

// periphery:ignore:all - API

@preconcurrency import FirebaseFirestore
import Foundation
import Grove
import GroveFirestore
import OSLog
import UserNotifications


/// Tracks notification-related events and persists them to firebase
final class NotificationTracking: Module, @unchecked Sendable {
    @Application(\.logger)
    private var logger
    
    @Dependency(FirebaseConfiguration.self)
    private var firebaseConfiguration
    
    func trackDidOpen(_ response: UNNotificationResponse) {
        print("response \(response)")
        print("userInfo \(response.notification.request.content.userInfo)")
        let event = TrackedNotificationEvent(
            timestamp: .now,
            timeZone: TimeZone.current.identifier,
            event: .opened,
            notificationId: response.notification.request.identifier,
            additionalStuff: String(describing: response.notification.request.content.userInfo)
        )
        Task {
            do {
                let doc = try await firebaseConfiguration.userDocumentReference
                    .collection("notificationTracking")
                    .document(UUID().uuidString)
                try await doc.setData(from: event)
            } catch {
                logger.error("Error: \(error)")
            }
        }
    }
}


extension NotificationTracking {
    private struct TrackedNotificationEvent: Encodable {
        enum Event: String, Encodable {
            case opened
        }
        
        let timestamp: Date
        let timeZone: String
        let event: Event
        let notificationId: String
        let additionalStuff: String
    }
}
