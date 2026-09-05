//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

@preconcurrency import FirebaseFirestore
import Foundation
import MyHeartCountsShared
import SwiftUI


@MainActor
@propertyWrapper
struct DailyNudge: DynamicProperty {
    struct Nudge: Sendable {
        let title: String
        let message: String
    }
    
    @Environment(\.calendar)
    private var cal
    
    @MHCFirestoreQuery(
        collection: .user(path: "notificationHistory"),
        sortBy: [.init(fieldName: "originalTimestamp", order: .reverse)],
        limit: 1,
        decoder: MUCUserNotificationDecoder()
    )
    private var notifications: [MHCUserNotification]
    
    var wrappedValue: Nudge? {
        if FeatureFlags.isTakingDemoScreenshots {
            return .demoNudge
        }
        guard let notificaton = notifications.first else {
            return nil
        }
        guard cal.isDateInToday(notificaton.originalTimestamp) || cal.isDateInYesterday(notificaton.originalTimestamp) else {
            return nil
        }
        return Nudge(title: notificaton.title, message: notificaton.body)
    }
}


extension DailyNudge {
    private struct MUCUserNotificationDecoder: MyHeartCountsShared::ValueTransformer {
        func transform(_ input: QueryDocumentSnapshot) throws -> MHCUserNotification {
            try input.data(as: MHCUserNotification.self)
        }
    }
}


extension DailyNudge.Nudge {
    static let demoNudge = Self(
        title: String(localized: "DEMO_NUDGE_TITLE"),
        message: String(localized: "DEMO_NUDGE_MESSAGE")
    )
}
