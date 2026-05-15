//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import OSLog
import Spezi
import SpeziFoundation


@MainActor
final class AppRefresh: Module, Sendable {
    // swiftlint:disable attributes
    @StandardActor private var standard: MyHeartCountsStandard
    @Application(\.logger) private var logger
    @Dependency(MHCBackgroundTasks.self) private var backgroundTasks
    // swiftlint:enable attributes
    
    func configure() {
        do {
            try backgroundTasks.register(.appRefresh(
                id: .generalAppRefresh,
                nextTriggerDate: .next(.hourly(calendar: .current, hours: [0, 12], minutes: [0]))
            ) {
                await self.standard.updateStudyDefinition()
            })
        } catch {
            logger.error("Error registering app refresh background task: \(error)")
        }
    }
}


extension MHCBackgroundTasks.TaskIdentifier {
    static let generalAppRefresh = Self("edu.stanford.MyHeartCounts.AppRefresh")
}
