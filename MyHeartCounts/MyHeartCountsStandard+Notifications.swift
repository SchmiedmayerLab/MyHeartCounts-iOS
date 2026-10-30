//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import Grove
import GroveFoundation
import GroveScheduler
import GroveStudy
import OSLog
@preconcurrency import UserNotifications


extension MyHeartCountsStandard: NotificationHandler {
    nonisolated func receiveIncomingNotification(_ notification: UNNotification) async -> UNNotificationPresentationOptions? {
        // we want notifications to always display, even when the app is running.
        [.badge, .banner, .list, .sound]
    }
    
    nonisolated func handleNotificationAction(_ response: UNNotificationResponse) async {
        await _handleNotificationAction(response)
    }
    
    @MainActor
    private func _handleNotificationAction(_ response: UNNotificationResponse) async {
        await notificationTracking.trackDidOpen(response)
        switch response.actionIdentifier {
        case UNNotificationDefaultActionIdentifier:
            // the user simply tapped the notification
            let cal = Calendar.current
            // resolves both the current key and the pre-Grove one, so notifications still pending from an
            // earlier build keep matching
            if let taskId = SchedulerNotifications.taskId(fromUserInfo: response.notification.request.content.userInfo),
               let task = try? await scheduler.queryTasks(for: cal.rangeOfDay(for: response.notification.date)).last(where: { $0.id == taskId }),
               let context = task.studyContext,
               let action = task.studyScheduledTaskAction {
                await logger.notice(
                    "DID TAP TASK-BOUND NOTI FOR \(task) (ctx: \(String(describing: context)); action: \(String(describing: action)))"
                )
            }
        default:
            break
        }
    }
}
