//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

// swiftlint:disable file_types_order

import Algorithms
import FirebaseFirestore
import Foundation
import MyHeartCountsShared
import OSLog
import Spezi
import SpeziAccount
import SpeziFirestore
import SpeziFoundation
import SpeziHealthKit
import SpeziStudy
import SwiftUI


struct AchievementsState: Codable {
    struct TriggerEvent: Codable {
        let triggerId: Achievement.Trigger.ID
        let timestamp: Date
    }
    
    struct MetricObservation: Codable {
        let timestamp: Date
        let value: Double
    }
    
    var triggerEvents: [TriggerEvent]
    /// - Note: "metric" here is not referring to the metric system, and rather to the fact that each entry belongs to some metric.
    var metricObservations: [Achievement.Metric: MetricObservation]
    
    init() {
        triggerEvents = []
        metricObservations = [:]
    }
}


// MARK: AchievementsManager

@Observable
final class AchievementsManager: Module, EnvironmentAccessible, @unchecked Sendable {
    // swiftlint:disable attributes
    @ObservationIgnored @Application(\.logger) private var logger
    @ObservationIgnored @Dependency(Account.self) private var account: Account?
    @ObservationIgnored @Dependency(StudyManager.self) private var studyManager: StudyManager?
    @ObservationIgnored @Dependency(FirebaseConfiguration.self) var firebaseConfiguration
    @ObservationIgnored @Dependency(HealthKit.self) private var healthKit
    // swiftlint:disable attributes
    
    /// Protects ``_achievements``
    @ObservationIgnored private let achievementsLock = RWLock()
    /*nonisolated(unsafe)*/ private var _achievements: [Achievement] = []
    
    var achievements: [Achievement] {
        achievementsLock.withReadLock {
            _achievements
        }
    }
    
    // TODO move this off the main actor, somehow!
    @MainActor private(set) var achievementsState: AchievementsState?
    
    @MainActor
    private var achievementTrackingDoc: DocumentReference {
        get throws {
            guard let studyId = studyManager?.studyEnrollments.first?.studyId else {
                throw NSError(mhcErrorCode: .unspecified, localizedDescription: "Not enrolled in study")
            }
            return try firebaseConfiguration.userDocumentReference.collection("achievementTracking").document(studyId.uuidString)
        }
    }
    
    
    nonisolated init() {}
    
    
    func configure() {
        Achievement.registerDefaultAchievements(with: self)
        Task {
            do {
                try await self.refresh()
            } catch {
                logger.error("Refresh failed: \(error)")
            }
        }
    }
    
    
    func register(achievement: Achievement) {
        register(achievements: CollectionOfOne(achievement))
    }
    
    func register(achievements newEntries: some Sequence<Achievement>) {
        achievementsLock.withWriteLock {
            var seenIds = _achievements.mapIntoSet(\.id)
            for new in newEntries where seenIds.insert(new.id).inserted {
                assert(
                    new.visibility != .secretUnlessNextInLadder || new.subcategory != nil,
                    "Achievement '\(new.id)' is .secretUnlessNext but has no subcategory — 'next' is undefined without a ladder."
                )
                self._achievements.append(new)
            }
        }
    }
    
    
    func refresh() async throws {
        let doc = try await achievementTrackingDoc
        // TODO
//        doc.addSnapshotListener(options: <#T##SnapshotListenOptions#>, listener: <#T##(DocumentSnapshot?, (any Error)?) -> Void#>)
        let state: AchievementsState
        if try await doc.getDocument().exists {
            state = try await doc.getDocument(as: AchievementsState.self)
        } else {
            state = .init()
        }
        await MainActor.run {
            self.achievementsState = state
        }
        if let enrollmentDate = await MainActor.run(body: { studyManager?.studyEnrollments.first?.enrollmentDate }) {
            try await updateEnrollmentStats(enrollmentDate: enrollmentDate)
            try await updateHealthMetrics(enrollmentDate: enrollmentDate)
        }
    }
    
    
    private func updateEnrollmentStats(enrollmentDate: Date) async throws {
        try await record(.completeEnrollment, timestamp: enrollmentDate)
        let now = Date()
        let cal = Calendar.current
        let enrollmentDate = cal.startOfDay(for: enrollmentDate)
        let numDays = cal.countDistinctDays(from: enrollmentDate, to: now)
        let numWeeks = cal.dateComponents([.weekOfYear], from: enrollmentDate, to: now).weekOfYear ?? (numDays / 7)
        let numMonths = cal.dateComponents([.month], from: enrollmentDate, to: now).month ?? (numWeeks / 4)
        let numYears = cal.dateComponents([.year], from: enrollmentDate, to: now).year ?? (numMonths / 12)
        try await record(.enrollmentDurationInDays, value: numDays, timestamp: now)
        try await record(.enrollmentDurationInWeeks, value: numWeeks, timestamp: now)
        try await record(.enrollmentDurationInMonths, value: numMonths, timestamp: now)
        try await record(.enrollmentDurationInYears, value: numYears, timestamp: now)
    }
    
    
    private func updateHealthMetrics(enrollmentDate: Date) async throws {
        for stats in (try? await healthKit.statisticsQuery(
            .stepCount,
            aggregatedBy: [.sum],
            over: .day,
            timeRange: .init(Calendar.current.startOfDay(for: enrollmentDate)..<Date.now)
        )) ?? [] {
            guard let stepCount = stats.sumQuantity()?.doubleValue(for: .count()) else {
                continue
            }
            try await record(.dailyStepCount, value: stepCount, timestamp: stats.timeRange.middle)
        }
    }
    
    // IDEA maybe add a function that updates muleiple triggers/metrics at once!!!
    
    func record(_ trigger: Achievement.Trigger, timestamp: Date) async throws {
        await MainActor.run {
            var state = achievementsState ?? .init()
            switch trigger.recordingMode {
            case .recordOnce:
                let hasEvent = state.triggerEvents.contains { $0.triggerId == trigger.id }
                if !hasEvent {
                    fallthrough
                }
            case .keepAll:
                state.triggerEvents.append(.init(triggerId: trigger.id, timestamp: timestamp))
            }
            self.achievementsState = state
        }
    }
    
    func record(_ metric: Achievement.Metric, value: some BinaryInteger, timestamp: Date) async throws {
        try await record(metric, value: Double(value), timestamp: timestamp)
    }
    
    func record(_ metric: Achievement.Metric, value: Double, timestamp: Date) async throws {
        await MainActor.run {
            var state = achievementsState ?? .init()
            if let oldEntry = state.metricObservations[metric] {
                switch metric.rule {
                case .atLeast: // tracking upwards
                    if value >= oldEntry.value {
                        state.metricObservations[metric] = .init(timestamp: timestamp, value: value)
                    }
                case .atMost: // tracking downwards
                    if value <= oldEntry.value {
                        state.metricObservations[metric] = .init(timestamp: timestamp, value: value)
                    }
                }
            } else {
                state.metricObservations[metric] = .init(timestamp: timestamp, value: value)
            }
            self.achievementsState = state
        }
    }
}


extension Achievement {
    /// Used to identify an "achievements ladder", i.e., a sequence of achievements that track the same event/metric, and unlock in order.
    ///
    /// Achievement ladders are implicitly derived from the achievements' ``Achievement/category`` and ``Achievement/subcategory`` values.
    /// All achievements with the same category and subcategory values belong to a ladder, if ``Achievement/Subcategory/formsLadder`` is enabled.
    /// The order within the ladder is based on the order in which the achievements were registered.
    ///
    /// For example, the app defines a series of "Walk N steps in a day" achievements, with N=(10k, 20k, 30k, ...).
    fileprivate struct Ladder: Hashable {
        let category: Achievement.Category
        let subcategory: Achievement.Subcategory
    }
    
    /// The achievement's ladder, if applicable.
    fileprivate var ladder: Ladder? {
        if let subcategory, subcategory.formsLadder {
            Ladder(category: category, subcategory: subcategory)
        } else {
            nil
        }
    }
}

extension AchievementsManager {
    enum AchievementsFilter: Sendable {
        /// No filtering is applied, i.e. all achievements are considered
        case none
        /// Only achievements from the specifiec category and subcategory are considered. If `subcategory` is nil, the filter will look only at the category.
        case category(Achievement.Category, subcategory: Achievement.Subcategory? = nil)
        
        fileprivate func evaluate(_ achievement: Achievement) -> Bool {
            switch self {
            case .none:
                true
            case .category(let category, subcategory: .none):
                achievement.category == category
            case let .category(category, subcategory: .some(subcategory)):
                achievement.category == category && achievement.subcategory == subcategory
            }
        }
    }
    
    /// An already unlocked achievement
    struct UnlockedAchievement: Sendable {
        let unlockDate: Date
        let achievement: Achievement
    }
    
    /// A yet-to-be unlocked achievement
    struct UpcomingAchievement: Sendable {
        let achievement: Achievement
        /// The achivement's current progress.
        ///
        /// Since this is representing an upcoming (i.e., yet to be unlocked) achievement, this value will always be in the range `0..<1`.
        let progress: Double
        let lastUpdate: Date?
    }
    
    
    enum AchievementState {
        case locked(progress: Double, lastUpdate: Date?)
        case unlocked(unlockDate: Date)
        
        /// The progress wrt unlocking this achievement, on a scale from `0` to `1`.
        ///
        /// - Note: Not all achievement support fractional progress reports; in these cases the value will be either `0` or `1`, but never anything inbetween.
        var progress: Double {
            switch self {
            case .locked(let progress, lastUpdate: _):
                progress
            case .unlocked:
                1
            }
        }
    }
    
    
    /// user-displayable number of achievements existing in the app
    var userDisplayableTotalAchievementCount: Int {
        achievements.count { $0.visibility != .internal }
    }
    
    /// user-displayable number of currently unlocked achievements
    @MainActor var userDisplayableUnlockedAchievementsCount: Int {
        achievements.count { $0.visibility != .internal && didUnlock($0) }
    }
    
    
    /// Returns all unlocked achievements, optionally sorted by the date they were unlocked
    @MainActor
    func unlockedAchievements(
        filter: AchievementsFilter = .none,
        sortByUnlockDate: Bool
    ) -> [UnlockedAchievement] {
        let unlocked = achievements.lazy
            .filter { filter.evaluate($0) }
            .compactMap { achievement -> UnlockedAchievement? in
                guard achievement.visibility != .internal else {
                    return nil
                }
                return switch self.state(of: achievement) {
                case .locked:
                    nil
                case .unlocked(let unlockDate):
                    UnlockedAchievement(unlockDate: unlockDate, achievement: achievement)
                }
            }
        return if sortByUnlockDate {
            unlocked.sorted(using: KeyPathComparator(\.unlockDate))
        } else {
            Array(unlocked)
        }
    }
    
    
    /// Whether `achievement` is currently the first still-locked level of its ladder, in registration order.
    ///
    /// Standalone achievements (no ladder) are trivially "next" while locked. Already-unlocked achievements
    /// return `false` (they aren't *locked* levels).
    @MainActor
    func isNextLockedLevel(_ achievement: Achievement) -> Bool {
        guard let ladder = achievement.ladder else {
            return !didUnlock(achievement)
        }
        return achievements.first { $0.ladder == ladder && !didUnlock($0) } == achievement
    }
    
    
    @MainActor
    func nextLockedAchievement(
        in category: Achievement.Category,
        subcategory: Achievement.Subcategory?
    ) -> Achievement? { // TODO also return an UpcomingAchievement?
        // TODO this kinda has the implicit assumption that the achievements will always be segmented into a head of unlocked ones, and a tail of locked ones...
        achievements.lazy
            .filter { AchievementsFilter.category(category, subcategory: subcategory).evaluate($0) }
            .first { !didUnlock($0) }
    }
    
    /// Computes a list of upcoming, currently still locked achievements.
    ///
    /// - parameter category: The category to fetch from. Set to `nil` to consider all categories.
    /// - parameter excluding: A set of ``Achievement``s that should not be included in the list. This filter is applied prior to `limit`.
    @MainActor
    func nextLockedAchievements(
        in category: Achievement.Category? = nil,
        excluding: Set<Achievement> = []
    ) -> [UpcomingAchievement] {
        // 1. user-visible + still-locked, carrying state so we don't recompute it for sorting/rendering.
        //    .internal and plain .secret are excluded; .secretUnlessNextInCategory is allowed
        //    (ladder-collapse below reveals only its next level and keeps later ones hidden).
        let candidates: [UpcomingAchievement] = achievements
            .compactMap { achievement in
                if let category, achievement.category != category {
                    return nil
                }
                switch achievement.visibility {
                case .internal, .secret:
                    return nil
                case .always, .secretUnlessNextInLadder:
                    break
                }
                guard case .locked(let progress, let lastUpdate) = self.state(of: achievement) else {
                    return nil
                }
                return UpcomingAchievement(achievement: achievement, progress: progress, lastUpdate: lastUpdate)
            }
        // 2. collapse each ladder to its first (= next) locked level, in authored order.
        //    NOTE: this is the "what's next" surface, so we collapse EVERY ladder to one level regardless
        //    of visibility — unlike `AchievementsView`, where only `.secretUnlessNext` hides future levels.
        var seenLadders = Set<Achievement.Ladder>()
        let collapsed = candidates.filter { entry in
            guard let key = entry.achievement.ladder else {
                // keep all standalone achievements
                return true
            }
            // for ladder-like achievements, we want to keep only the first one
            return seenLadders.insert(key).inserted
        }
        // 3. closest-to-unlock first; stable tie-break preserves authored order for equal progress
        return collapsed
            .enumerated()
            .sorted {
                $0.element.progress != $1.element.progress
                    ? $0.element.progress > $1.element.progress
                    : $0.offset < $1.offset
            }
            .map(\.element)
            .filter { !excluding.contains($0.achievement) }
    }
    
    @MainActor
    func didUnlock(_ achievement: Achievement) -> Bool {
        switch state(of: achievement) {
        case .locked: false
        case .unlocked: true
        }
    }
    
    @MainActor
    func unlockProgress(of achievement: Achievement) -> Double {
        state(of: achievement).progress
    }
    
    @MainActor
    func state(of achievement: Achievement) -> AchievementState {
        guard let state = self.achievementsState else {
            return .locked(progress: 0, lastUpdate: nil)
        }
        switch achievement.kind {
        case let .event(trigger, predicate):
            return predicate(state.triggerEvents.filter { $0.triggerId == trigger.id })
        case let .threshold(metric, target):
            guard let observation = state.metricObservations[metric] else {
                return .locked(progress: 0, lastUpdate: nil)
            }
            let progress: Double = switch metric.rule {
            case .atLeast(let base): // tracking upwards
                if let base {
                    ((observation.value - base) / (target - base)).clamped(to: 0...1)
                } else {
                    (observation.value <= target) ? 1 : 0
                }
            case .atMost(let base): // tracking downwards
                if let base {
                    ((base - observation.value) / (base - target)).clamped(to: 0...1)
                } else {
                    (observation.value <= target) ? 1 : 0
                }
            }
            return if progress >= 1 {
                .unlocked(unlockDate: observation.timestamp)
            } else {
                .locked(progress: progress, lastUpdate: observation.timestamp)
            }
        }
    }
}
