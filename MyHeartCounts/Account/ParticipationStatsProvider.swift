//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import Spezi
import SpeziHealthKit
import SpeziHealthKitUI
import SpeziScheduler
import SpeziStudy


@Observable
@MainActor
final class ParticipationStatsProvider: Module, EnvironmentAccessible {
    // swiftlint:disable attributes
    @ObservationIgnored @Dependency(StatsStore.self) private var statsStore: StatsStore?
    @ObservationIgnored @Dependency(StudyManager.self) private var studyManager: StudyManager?
    @ObservationIgnored @Dependency(Scheduler.self) private var scheduler
    // swiftlint:enable attributes
    
    nonisolated init() {}
}


extension ParticipationStatsProvider {
    struct Stats: Sendable {
        let enrollment: EnrollmentStats
        let appEngagement: AppEngagementStats?
        let taskEngagement: TaskEngagementStats
        let health: ParticipationHealthStats
    }
    
    
    struct EnrollmentStats: Sendable {
        let enrollmentDate: Date
        let numDaysEnrolled: Int
        let numWeeksEnrolled: Int
        let numMonthsEnrolled: Int
        let numYearsEnrolled: Int
    }
    
    struct AppEngagementStats: Sendable {
        /// The user's current streak of opening the app at least once per week.
        let currentLaunchAppStreak: Int
        /// The user's longest recorded streak of opening the app at least once per week.
        let longestLaunchAppStreak: Int
    }
    
    struct TaskEngagementStats: Sendable {
        let totalCompleted: Int
        let questionnairesCompleted: Int
        let articlesRead: Int
        let ecgsRecorded: Int?
        let walkRunTestsCompleted: Int
    }
    
    
    struct ParticipationHealthStats: Sendable {
        struct WorkoutInfo: Sendable {
            let numWorkouts: Int
            let totalDuration: Measurement<UnitDuration>
        }
        
        struct LongestWorkoutInfo: Sendable {
            let date: Date
            let activityType: HKWorkoutActivityType
            let duration: Measurement<UnitDuration>
        }
        
        struct HealthHighlights: Sendable {
            struct Entry<Value: Sendable>: Sendable { // swiftlint:disable:this nesting
                let date: Date
                let value: Value
            }
            
            let bestDailySteps: Entry<Int>?
            let longestWorkout: LongestWorkoutInfo?
            let maxHeartRateBPM: Int?
            let avgRestingHeartRateBPM: Int?
        }
        
        let totalSteps: Int?
        let totalActiveEnergyKcal: Double?
        let totalDistanceWalkingRunning: Measurement<UnitLength>?
        let totalExerciseTime: Measurement<UnitDuration>?
        let totalFlightsClimbed: Int?
        let totalHeartbeats: Int?
        let totalSleepTime: Measurement<UnitDuration>?
        let workoutInfo: WorkoutInfo?
        let highlights: HealthHighlights
    }
}


extension ParticipationStatsProvider {
    struct RefreshIdentity: Hashable {
        let enrollmentID: StudyEnrollment.ID
        let enrollmentDate: Date
        let storeID: ObjectIdentifier?
        let sessionRevision: Int?
    }

    func refreshIdentity(for enrollment: StudyEnrollment) -> RefreshIdentity {
        RefreshIdentity(
            enrollmentID: enrollment.id,
            enrollmentDate: enrollment.enrollmentDate,
            storeID: statsStore.map(ObjectIdentifier.init),
            sessionRevision: statsStore?.sessionRevision
        )
    }

    private func makeQueryContext(for enrollment: StudyEnrollment) throws -> QueryContext {
        guard let statsStore else {
            throw StatsStore.Error.unavailable
        }
        let session = try statsStore.context().1
        let identity = refreshIdentity(for: enrollment)
        try validateEnrollment(identity)
        let now = Date()
        let cal = Calendar.current
        let enrollmentDate = enrollment.enrollmentDate
        let endOfDay = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now)) ?? now
        let timeRange = enrollmentDate < now ? cal.startOfDay(for: enrollmentDate)..<endOfDay : now..<now
        return QueryContext(
            store: statsStore,
            session: session,
            identity: identity,
            timeRange: timeRange,
            enrollment: EnrollmentStats(
                enrollmentDate: enrollmentDate,
                numDaysEnrolled: cal.countDistinctDays(from: enrollmentDate, to: now),
                numWeeksEnrolled: cal.countDistinctWeeks(from: enrollmentDate, to: now),
                numMonthsEnrolled: cal.countDistinctMonths(from: enrollmentDate, to: now),
                numYearsEnrolled: cal.countDistinctYears(from: enrollmentDate, to: now)
            ),
            taskEngagement: computeTaskEngagementStats(
                studyId: enrollment.studyId,
                enrollmentTimeRange: timeRange.lowerBound..<max(timeRange.lowerBound, now)
            )
        )
    }

    private func validateEnrollment(_ identity: RefreshIdentity) throws {
        guard let enrollment = studyManager?.enrollment(withId: identity.enrollmentID),
              refreshIdentity(for: enrollment) == identity else {
            throw StatsStore.Error.sessionChanged
        }
    }

    private func computeTaskEngagementStats(
        studyId: UUID,
        enrollmentTimeRange: Range<Date>
    ) -> TaskEngagementStats {
        let events: [Event] = (try? scheduler.queryEvents(for: enrollmentTimeRange)) ?? []
        let studyEvents = events.filter { event in
            event.isCompleted && event.task.studyContext?.studyId == studyId
        }
        var perCategory: [Task.Category: Int] = [:]
        for event in studyEvents {
            if let cat = event.task.category {
                perCategory[cat, default: 0] += 1
            }
        }
        let walkRun = (perCategory[.timedWalkingTest] ?? 0) + (perCategory[.timedRunningTest] ?? 0)
        return TaskEngagementStats(
            totalCompleted: studyEvents.count,
            questionnairesCompleted: perCategory[.questionnaire] ?? 0,
            articlesRead: perCategory[.informational] ?? 0,
            ecgsRecorded: nil,
            walkRunTestsCompleted: walkRun
        )
    }
}


extension ParticipationStatsProvider {
    private struct QueryContext {
        let store: StatsStore
        let session: StatsStore.Session
        let identity: RefreshIdentity
        let timeRange: Range<Date>
        let enrollment: EnrollmentStats
        let taskEngagement: TaskEngagementStats
    }

    @MainActor
    private final class LiveStats {
        var inputs = HealthSnapshots()
        let context: QueryContext
        let continuation: AsyncThrowingStream<Stats, any Error>.Continuation

        init(context: QueryContext, continuation: AsyncThrowingStream<Stats, any Error>.Continuation) {
            self.context = context
            self.continuation = continuation
        }

        func publish() {
            let now = min(Date.now, context.timeRange.upperBound)
            let timeRange = context.timeRange.lowerBound..<max(context.timeRange.lowerBound, now)
            let engagement = context.taskEngagement
            continuation.yield(Stats(
                enrollment: context.enrollment,
                appEngagement: nil, // App launch tracking is not available yet.
                taskEngagement: TaskEngagementStats(
                    totalCompleted: engagement.totalCompleted,
                    questionnairesCompleted: engagement.questionnairesCompleted,
                    articlesRead: engagement.articlesRead,
                    ecgsRecorded: inputs.ecgCount(before: now),
                    walkRunTestsCompleted: engagement.walkRunTestsCompleted
                ),
                health: inputs.healthStats(in: timeRange)
            ))
        }
    }

    /// Each metric has an independent typed subscription. Replacing its snapshot also reflects backfill and deletions.
    func updates(for enrollment: StudyEnrollment) -> AsyncThrowingStream<Stats, any Error> {
        let (stream, continuation) = AsyncThrowingStream<Stats, any Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let task = Swift::Task { @MainActor in
            do {
                let context = try makeQueryContext(for: enrollment)
                let live = LiveStats(context: context, continuation: continuation)
                live.publish()
                await observeHealthStats(live)
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    private func observeHealthStats(_ live: LiveStats) async {
        let range = live.context.timeRange
        await withDiscardingTaskGroup { group in
            for query in Self.quantityQueries {
                group.addTask { @MainActor @Sendable in
                    await self.consume(
                        Self.quantityRequest(query.metric, in: range, aggregation: query.aggregation, daily: query.daily),
                        live: live,
                        at: query.keyPath
                    )
                }
            }
            group.addTask { @MainActor @Sendable in
                await self.consume(.sleepSessions(in: .init(range), sourcePolicy: .automatic), live: live, at: \.sleep)
            }
            group.addTask { @MainActor @Sendable in
                await self.consume(.workouts(in: .init(range), sourcePolicy: .automatic), live: live, at: \.workouts)
            }
            group.addTask { @MainActor @Sendable in
                await self.consume(.electrocardiograms(in: .init(range), sourcePolicy: .automatic), live: live, at: \.ecgs)
            }
        }
    }

    private func consume<Element>(
        _ request: StatsStore.Request<Element>,
        live: LiveStats,
        at keyPath: any WritableKeyPath<HealthSnapshots, StatsStore.Snapshot<Element>?> & Sendable
    ) async {
        do {
            for try await snapshot in live.context.store.updates(for: request) {
                try validate(live.context)
                live.inputs[keyPath: keyPath] = snapshot
                live.publish()
            }
        } catch {
            guard !Swift::Task.isCancelled else {
                return
            }
            do {
                try validate(live.context)
                live.inputs[keyPath: keyPath] = nil
                live.publish()
            } catch {
                live.continuation.finish(throwing: error)
            }
        }
    }

    private func validate(_ context: QueryContext) throws {
        try Swift::Task.checkCancellation()
        try context.store.validate(context.session)
        try validateEnrollment(context.identity)
    }
}
