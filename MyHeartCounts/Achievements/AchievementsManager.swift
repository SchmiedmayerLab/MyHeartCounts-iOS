//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

// swiftlint:disable all

import Algorithms
import FirebaseFirestore
import Foundation
import Spezi
import SpeziAccount
import SpeziHealthKit
import SpeziStudy
import SpeziFirestore
import SFSafeSymbols
import SwiftUI
import OSLog
import SpeziFoundation
import MyHeartCountsShared


// MARK: Achievement Definitions

/// A tracked goal the user can unlock by satisfying some condition.
///
/// - Note: ``Achievement`` conforms to both `Equatable` and `Hashable`.
///     Equality and hashing depend solely on the achievement's ``id``. All other properties are ignored.
///     It is the responsibility of the application to ensure that there never exist two or more achievements with equal ``id``s.
struct Achievement: Identifiable, Sendable {
    typealias MetricValue = Double
    
    enum Kind: Sendable {
        /// An achievement that unlocks based on the events recorded for a trigger.
        ///
        /// - parameter predicate: The function that determines whether the achievement's condition is fulfilled, i.e., whether the achievement is unlocked.
        ///     The trigger events passed to the closure are sorted in increasing order w.r.t. their timestamps.
        ///     Returns the ``AchievementsState/TriggerEvent`` that caused the achievement to get unlocked, or `nil` if the achievement is still locked. TODO UPDATE NO LONGER TRUE
        case event(trigger: Trigger, predicate: @Sendable (_ events: [AchievementsState.TriggerEvent]) -> AchievementsManager.AchievementState)
        /// An achievement that unlocks when a value associated with some metric reaches a threshold.
        case threshold(metric: Metric, target: MetricValue)
        
        /// An achievement that unlocks when a "thing" happens at least once.
        static func eventOnce(trigger: Trigger) -> Self {
            .counting(trigger: trigger, target: 1)
        }
        
        /// An achievement that unlocks when the amount of times a specific "thing" happened exceeds a threshold.
        static func counting(trigger: Trigger, target: Int) -> Self {
            // TODO:
            // 1. do we want to support negative trigger-based achievement kinds?
            //    ie, the achievement would be unlocked as long as you don't have any triggers, but become locked once they exist?
            //    what would the unlockDate be in that case?
            // 2. if there is an "trigger once" achievement that can be unlocked multiple times (bc the trigger is fired multiple times),
            //    should we use the first, or the latest, date for the completion? (currently it's the first, which probably is what
            //    we want most if not all of the time...
            .event(trigger: trigger) { events in
                guard target > 0 else {
                    return .unlocked(unlockDate: .now)
                }
                // assuming that events is sorted in ascending order, this will give us the first event that fulfilled the target count
                if let event = events[safe: target - 1] {
                    return .unlocked(unlockDate: event.timestamp)
                } else {
                    return .locked(
                        progress: Double(events.count) / Double(target),
                        lastUpdate: events.last?.timestamp
                    )
                }
            }
        }
    }
    
    struct Trigger: Identifiable, Hashable, Codable, Sendable {
        enum RecordingMode: String, Hashable, Codable, Sendable {
            /// The ``AchievementsManager`` will keep records of all times the trigger was fired.
            case keepAll = "keep-all"
            /// The ``AchievementsManager`` will keep record of only the first time the trigger was fired.
            case recordOnce = "record-once"
        }
        let id: String
        let recordingMode: RecordingMode
    }
    
    struct Metric: Identifiable, Hashable, Codable, Sendable {
        let id: String
        let rule: ThresholdRule
    }
    
    struct Category: Identifiable, Hashable, Sendable {
        let id: String
        let title: LocalizedStringResource
    }
    
    struct Subcategory: Identifiable, Hashable, Sendable {
        let id: String
        let formsLadder: Bool
    }
    
    enum ThresholdRule: RawRepresentable<String>, Hashable, Codable, Sendable {
        /// A rule that triggers if the metric's observed value is greater than or equal to its target value.
        /// - parameter base: The rule's base value. Used to compute the user's progress in reaching the target.
        ///     For example, a "daily step count" metric would set its base to `0`, since that's the starting point from which any progress should be computed.
        case atLeast(base: MetricValue?)
        /// A rule that triggers if the metric's observed value is less than or equal to its target value.
        /// - parameter base: The rule's base value. Used to compute the user's progress in reaching the target.
        ///     For example, a "resting heart rate" metric could set its base to `90`, since that's the starting point from which any progress should be computed.
        case atMost(base: MetricValue?)
        
        var rawValue: String {
            switch self {
            case .atLeast(.none):
                "atLeast"
            case .atLeast(base: .some(let value)):
                "atLeast(\(value.description))"
            case .atMost(.none):
                "atMost"
            case .atMost(base: .some(let value)):
                "atMost(\(value.description))"
            }
        }
        
        init?(rawValue: String) {
            let name: Substring
            let value: MetricValue?
            if let parenIdx = rawValue.firstIndex(of: "(") {
                guard rawValue.last == ")", let val = MetricValue(rawValue[parenIdx...].dropFirst().dropLast()) else {
                    return nil
                }
                name = rawValue[..<parenIdx]
                value = val
            } else {
                name = rawValue[...]
                value = nil
            }
            switch name {
            case "atLeast":
                self = .atLeast(base: value)
            case "atMost":
                self = .atMost(base: value)
            default:
                return nil
            }
        }
    }
    
    enum Visibility {
        /// The achievement is always fully visible
        case always
        /// The achievement's title/description/symbol/etc are hidden while it isn't yet unlocked.
        case secret
        /// The achievement is never displayed to the user.
        case `internal`
        /// The achievement is hidden until it is the next still-locked level of its ladder.
        ///
        /// Use this for the levels of a progression (a `(category, subcategory)` ladder) so the user only ever
        /// sees the immediate next goal plus the levels they've already unlocked — later levels stay hidden.
        /// - Important: An achievement using this visibility **must** have a ``Achievement/subcategory``;
        ///     "next" is undefined without a ladder.
        case secretUnlessNextInLadder
    }
    
    enum Icon: Sendable {
        case symbol(SFSymbol)
    }
    
    let id: String
    let category: Category
    let subcategory: Subcategory?
    let kind: Kind
    let title: LocalizedStringResource
    let description: LocalizedStringResource
    let symbol: SFSymbol
    let visibility: Visibility
}


extension Achievement: Hashable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}


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
    @ObservationIgnored @Application(\.logger) private var logger
    @ObservationIgnored @Dependency(Account.self) private var account: Account?
    @ObservationIgnored @Dependency(StudyManager.self) private var studyManager: StudyManager? // TODO does this need to be optional?
    @ObservationIgnored @Dependency(FirebaseConfiguration.self) var firebaseConfiguration
    @ObservationIgnored @Dependency(HealthKit.self) private var healthKit
    
    /// Protects ``_achievements``
    @ObservationIgnored private let achievementsLock = RWLock()
    /*nonisolated(unsafe)*/ private var _achievements: [Achievement] = []
    
    var achievements: [Achievement] {
        // TODO can probablu elide the lock if running on the main actor (not that it'd be worth it...)
        achievementsLock.withReadLock {
            _achievements
        }
    }
    
    
    @MainActor private(set) var achievementsState: AchievementsState? // TODO move this off the main actor, somehow!
    
    nonisolated init() {}
    
    @MainActor
    private var achievementTrackingDoc: DocumentReference {
        get throws {
            guard let studyId = studyManager?.studyEnrollments.first?.studyId else {
                throw NSError(mhcErrorCode: .unspecified, localizedDescription: "Not enrolled in study")
            }
            return try firebaseConfiguration.userDocumentReference.collection("achievementTracking").document(studyId.uuidString)
        }
    }
    
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
    
    // TODO add a function that updates muleiple triggers/metrics at once!!!
    
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
        logger.notice("Recording Metric \(metric.id) (value: \(value) @ \(timestamp))")
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


protocol _AchievementProjectable {
    var _achievement: Achievement { get }
}

extension Achievement: _AchievementProjectable {
    var _achievement: Achievement { self }
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
    
    
    /// user-displayable number of achievements existing in the app
    var userDisplayableTotalAchievementCount: Int {
        achievements.count { $0.visibility != .internal }
    }
    
    /// user-displayable number of currently unlocked achievements
    @MainActor var userDisplayableUnlockedAchievementsCount: Int {
        achievements.count { $0.visibility != .internal && didUnlock($0) }
    }
    
    
    struct UnlockedAchievement: _AchievementProjectable, Sendable {
        let unlockDate: Date
        let achievement: Achievement
        
        var _achievement: Achievement { achievement}
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
    
    
//    /// The ladder an achievement belongs to, or `nil` if it's a standalone goal (no subcategory).
//    ///
//    /// A "ladder" is identified purely structurally, by `(category, subcategory)` — visibility plays no
//    /// part. Whether later levels of a ladder are hidden is a separate, visibility-driven concern
//    /// (see ``Achievement/Visibility/secretUnlessNext``).
//    private func ladderKey(for achievement: Achievement) -> LadderKey? {
//        achievement.subcategory.map { LadderKey(category: achievement.category, subcategory: $0) }
//    }

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
    
    struct UpcomingAchievement: _AchievementProjectable, Sendable {
        let achievement: Achievement
        /// The achivement's current progress.
        ///
        /// Since this is representing an upcoming (i.e., yet to be unlocked) achievement, this value will always be in the range `0..<1`.
        let progress: Double
        let lastUpdate: Date?
        var _achievement: Achievement { achievement }
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
            .sorted { $0.element.progress != $1.element.progress
                ? $0.element.progress > $1.element.progress
                : $0.offset < $1.offset }
            .map(\.element)
            .filter { !excluding.contains($0.achievement) }
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
