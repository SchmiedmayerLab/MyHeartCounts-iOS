//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

// swiftlint:disable all

import Foundation
import HealthKit
import MHCStudyDefinition
import SFSafeSymbols
import SpeziFoundation
import SpeziHealthKit
import SpeziScheduler
import SpeziStudy
import SpeziViews
import SwiftUI
import OSLog
import Spezi


@Observable
@MainActor // ???
final class ParticipationStatsProvider: Module {
    @ObservationIgnored @Dependency(HealthKit.self) private var healthKit
    @ObservationIgnored @Dependency(Scheduler.self) private var scheduler
    
    private let enrollment: StudyEnrollment
    private var timeRange: Range<Date>
    
    init(enrollment: StudyEnrollment) {
        self.enrollment = enrollment
        self.timeRange = Self.enrollmentTimeRange(for: enrollment, upTo: .now)
    }
    
    static func enrollmentTimeRange(for enrollment: StudyEnrollment, upTo now: Date) -> Range<Date> {
        let startDate = enrollment.enrollmentDate
        return if startDate < now {
            startDate..<now
        } else {
            now..<now
        }
    }
}


extension ParticipationStatsProvider {
    struct Stats: Sendable {
        let enrollmentDate: Date
        let numDaysEnrolled: Int
        let numWeeksEnrolled: Int
        let taskEngagement: TaskEngagementStats
        let health: HealthStats
    }
    
    struct TaskEngagementStats: Sendable {
        static let empty = Self(
            totalCompleted: 0,
            questionnairesCompleted: 0,
            articlesRead: 0,
            ecgsRecorded: 0,
            walkRunTestsCompleted: 0,
            activeDays: 0,
            daysSinceEnrollment: 0,
            currentStreak: 0,
            longestStreak: 0
        )
        let totalCompleted: Int
        let questionnairesCompleted: Int
        let articlesRead: Int
        let ecgsRecorded: Int
        let walkRunTestsCompleted: Int
        let activeDays: Int
        let daysSinceEnrollment: Int
        let currentStreak: Int
        let longestStreak: Int
    }
    
    struct HealthStats: Sendable {
        struct WorkoutInfo {
            let numWorkouts: Int
            let totalDuration: Measurement<UnitDuration>
        }
        
        static let empty = Self(
            totalSteps: nil,
            totalActiveEnergyKcal: nil,
            totalDistanceWalkingRunning: nil,
            totalExerciseTime: nil,
            totalFlightsClimbed: nil,
            totalHeartbeats: nil,
            totalSleepTime: nil,
            workoutInfo: nil
        )
        
        let totalSteps: Int?
        let totalActiveEnergyKcal: Double?
        let totalDistanceWalkingRunning: Measurement<UnitLength>?
        let totalExerciseTime: Measurement<UnitDuration>?
        let totalFlightsClimbed: Int?
        let totalHeartbeats: Int?
        let totalSleepTime: Measurement<UnitDuration>?
        let workoutInfo: WorkoutInfo?
    }
}


extension ParticipationStatsProvider {
    func computeStats(for enrollment: StudyEnrollment) async throws -> Stats {
        let cal = Calendar.current
//        async let healthStats = (try? computeHealthStats(for: enrollment)) ?? .empty
//        async let taskEngagement = (try? computeTaskEngagementStats(for: enrollment)) ?? .empty
        return Stats(
            enrollmentDate: enrollment.enrollmentDate,
            numDaysEnrolled: cal.countDistinctDays(from: enrollment.enrollmentDate, to: .now),
            numWeeksEnrolled: cal.countDistinctWeeks(from: enrollment.enrollmentDate, to: .now),
//            taskEngagement: await taskEngagement,
//            health: await healthStats
            taskEngagement: .empty,
            health: .empty
        )
    }
    
    private func computeTaskEngagementStats(for enrollment: StudyEnrollment) async throws -> TaskEngagementStats {
        // TODO
        throw NSError(mhcErrorCode: .unspecified, localizedDescription: "")
    }
    
    private func computeHealthStats(for enrollment: StudyEnrollment) async throws -> HealthStats {
        // TODO
        throw NSError(mhcErrorCode: .unspecified, localizedDescription: "")
    }
}


extension ParticipationStatsProvider {
    func refresh() {
        // updating the time range here will trigger the task above, which will update the stats
        timeRange = Self.enrollmentTimeRange(for: enrollment, upTo: .now)
    }
}
