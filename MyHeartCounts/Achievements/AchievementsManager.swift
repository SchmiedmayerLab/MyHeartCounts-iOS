//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

// swiftlint:disable file_length

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


/// Manages tracked achievements and syncs them with Firebase.
@Observable
final class AchievementsManager: Module, EnvironmentAccessible, @unchecked Sendable {
    struct State: Hashable, Codable, Sendable {
        struct TriggerEvent: Hashable, Codable, Sendable {
            let triggerId: Achievement.Trigger.ID
            let timestamp: Date
        }
        
        struct MetricObservation: Hashable, Codable, Sendable {
            let timestamp: Date
            let value: Double
        }
        
        /// The version of the ``State`` type.
        ///
        /// Used to enable potential future evolution of the type.
        fileprivate let version: UInt
        
        fileprivate var triggerEvents: Set<TriggerEvent>
        /// - Note: "metric" here is not referring to the metric system, and rather to the fact that each entry belongs to some metric.
        fileprivate var metricObservations: [Achievement.Metric.ID: MetricObservation]
        
        fileprivate init() {
            version = 1
            triggerEvents = []
            metricObservations = [:]
        }
    }
    
    
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
    
    /// The single in-flight sync. All sync funnels through this one task, so two syncs can never
    /// interleave their read-merge-write. Cleared by the task itself (via `defer`) on completion.
    @MainActor private var runningSync: Task<Void, any Error>?
    /// Set whenever local state changes; tells an in-flight sync loop it must run another pass.
    @MainActor private var syncDirty = false
    /// Pending debounce timer for a requested-but-not-yet-started sync.
    @MainActor private var debounceTask: Task<Void, Never>?
    @MainActor private var achievementsState = State() {
        didSet {
            if achievementsState != oldValue {
                scheduleSync()
            }
        }
    }
    
    @MainActor
    private var achievementTrackingDoc: DocumentReference {
        get throws {
            guard let studyId = studyManager?.studyEnrollments.first?.studyId else {
                throw NSError(mhcErrorCode: .unspecified, localizedDescription: "Not enrolled in study")
            }
            return try firebaseConfiguration.userDocumentReference.collection("achievementTracking").document(studyId.uuidString)
        }
    }
    
    /// Trigger IDs whose events collapse to a single (earliest) entry when merging two states.
    private var recordOnceTriggerIDs: Set<Achievement.Trigger.ID> {
        achievements.reduce(into: []) { result, achievement in
            switch achievement.kind {
            case .event(let trigger, predicate: _):
                if trigger.recordingMode == .recordOnce {
                    result.insert(trigger.id)
                }
            case .threshold:
                break
            }
        }
    }
    
    
    private var metricRules: [Achievement.Metric.ID: Achievement.ThresholdRule] {
        achievements.reduce(into: [:]) { result, achievement in
            switch achievement.kind {
            case .threshold(let metric, target: _):
                result[metric.id] = metric.rule
            case .event:
                break
            }
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
                    "Achievement '\(new.id)' is .secretUnlessNext but has no subcategory. 'next' is undefined without a ladder."
                )
                self._achievements.append(new)
            }
        }
    }
    
    
    func refresh() async throws {
        // make sure the local version is up-to-date
        try await syncNow()
        if let enrollmentDate = await MainActor.run(body: { studyManager?.studyEnrollments.first?.enrollmentDate }) {
            await updateEnrollmentStats(enrollmentDate: enrollmentDate)
            await updateHealthMetrics(enrollmentDate: enrollmentDate)
        }
    }
    
    
    // TODO
    //    @MainActor
    //    private func observeServerSideChanges() throws {
    //        let doc = try self.achievementTrackingDoc
    //        doc.snapshots
    //    }
}


// MARK: Sync

extension AchievementsManager {
    /// Scheduled a debounced sync.
    @MainActor
    private func scheduleSync() {
        syncDirty = true
        // A running sync will pick up `syncDirty` and run another pass; a pending debounce will fire
        // on its own. In either case there's nothing more to schedule.
        guard runningSync == nil, debounceTask == nil else {
            return
        }
        debounceTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            self.debounceTask = nil
            do {
                try await self._runSync()
            } catch {
                self.logger.error("Scheduled sync failed: \(error)")
            }
        }
    }
    
    /// Performs an immediate sync between the local state and the firebase state.
    @MainActor
    func syncNow() async throws {
        debounceTask?.cancel()
        debounceTask = nil
        syncDirty = true // guarantees a coalesced caller still gets one pass over the latest state
        try await _runSync()
    }
    
    /// Performs a sync between the local state and the firebase state.
    ///
    /// It is safe to call this function while another sync is already in progress.
    /// It also is safe to mutate ``achievementsState`` while a sync is in progress; the changes will be picked up and synced as well.
    @MainActor
    private func _runSync() async throws { // swiftlint:disable:this function_body_length
        if let runningSync {
            try await runningSync.value
            return
        }
        /// Performs a single read-merge-write pass against the cloud document
        let syncImpl = { @MainActor () async throws in
            let doc = try self.achievementTrackingDoc
            let snapshot = try await doc.getDocument()
            // Capture the state this pass commits and clear the dirty flag in the SAME synchronous turn.
            // Anything recorded after this line re-sets `syncDirty` (handled by the next pass); anything
            // recorded before (including during the fetch above) is included in `local`.
            let local = self.achievementsState
            self.syncDirty = false
            guard snapshot.exists else {
                // No cloud doc yet: create it, but never write empty state over the server (e.g. a
                // fresh/offline launch before anything has been recorded).
                guard !local.isEmpty else {
                    return
                }
                do {
                    try await doc.setData(from: local)
                } catch {
                    self.syncDirty = true // upload failed: keep the change pending so runSync re-arms
                    throw error
                }
                return
            }
            let cloud = try snapshot.data(as: State.self)
            // Fold cloud into the captured local state (least-upper-bound). `merged >= local`, so
            // adopting it never regresses local progress.
            let merged = local.merging(
                cloud,
                recordOnceTriggerIDs: self.recordOnceTriggerIDs,
                metricRuleThresholds: self.metricRules
            )
            if merged != self.achievementsState {
                self.achievementsState = merged
            }
            guard merged != cloud else {
                return // cloud already has everything; nothing to upload
            }
            do {
                try await doc.setData(from: merged)
            } catch {
                self.syncDirty = true // upload failed: keep the change pending so runSync re-arms
                throw error
            }
        }
        let task = Task { @MainActor in
            // Cleared synchronously with the loop's exit decision: on the serial executor no `record()`
            // can interleave between the final `while self.syncDirty` read and this assignment.
            defer {
                runningSync = nil
            }
            repeat {
                try await syncImpl()
            } while syncDirty
        }
        runningSync = task
        defer {
            // By the time we resume here, the task's own defer has already cleared `runningSync`.
            // If a change is still pending (a `record(...)` that landed in the teardown gap, or a pass
            // that threw with `syncDirty` still set), re-arm a debounced retry now that we are no
            // longer the runner (so `scheduleSync`'s `runningSync == nil` guard lets it through).
            if syncDirty {
                scheduleSync()
            }
        }
        try await task.value
    }
}


// MARK: Mutations

extension AchievementsManager {
    @MainActor
    private func updateEnrollmentStats(enrollmentDate: Date) async {
        record(.completeEnrollment, timestamp: enrollmentDate)
        let now = Date()
        let cal = Calendar.current
        let enrollmentDate = cal.startOfDay(for: enrollmentDate)
        let numDays = cal.countDistinctDays(from: enrollmentDate, to: now)
        let numWeeks = cal.dateComponents([.weekOfYear], from: enrollmentDate, to: now).weekOfYear ?? (numDays / 7)
        let numMonths = cal.dateComponents([.month], from: enrollmentDate, to: now).month ?? (numWeeks / 4)
        let numYears = cal.dateComponents([.year], from: enrollmentDate, to: now).year ?? (numMonths / 12)
        record(.enrollmentDurationInDays, value: numDays, timestamp: now)
        record(.enrollmentDurationInWeeks, value: numWeeks, timestamp: now)
        record(.enrollmentDurationInMonths, value: numMonths, timestamp: now)
        record(.enrollmentDurationInYears, value: numYears, timestamp: now)
    }
    
    @MainActor
    private func updateHealthMetrics(enrollmentDate: Date) async {
        for stats in (try? await healthKit.statisticsQuery(
            .stepCount,
            aggregatedBy: [.sum],
            over: .day,
            timeRange: .init(Calendar.current.startOfDay(for: enrollmentDate)..<Date.now)
        )) ?? [] {
            guard let stepCount = stats.sumQuantity()?.doubleValue(for: .count()) else {
                continue
            }
            record(.dailyStepCount, value: stepCount, timestamp: stats.timeRange.middle)
        }
    }
    
    @MainActor
    func record(_ trigger: Achievement.Trigger, timestamp: Date) {
        achievementsState.record(trigger, timestamp: timestamp)
    }
    
    @MainActor
    func record(_ metric: Achievement.Metric, value: some BinaryInteger, timestamp: Date) {
        record(metric, value: Double(value), timestamp: timestamp)
    }
    
    @MainActor
    func record(_ metric: Achievement.Metric, value: Double, timestamp: Date) {
        achievementsState.record(metric, value: value, timestamp: timestamp)
    }
}


extension AchievementsManager.State {
    fileprivate var isEmpty: Bool {
        triggerEvents.isEmpty && metricObservations.isEmpty
    }
    
    /// Least-upper-bound merge of two states (commutative, idempotent, monotone).
    ///
    /// - `triggerEvents` are unioned, except `.recordOnce` triggers (identified by `recordOnceTriggerIDs`),
    ///   for which only the earliest event per `triggerId` is kept, otherwise a raw union of two states
    ///   holding the same logical one-shot event with differing timestamps would permanently duplicate it.
    /// - `metricObservations` are merged by `metric.rule` (`.atLeast` -> max value, `.atMost` -> min
    ///   value; ties on value resolve to the earliest timestamp to stay commutative).
    fileprivate func merging(
        _ other: Self,
        recordOnceTriggerIDs: Set<Achievement.Trigger.ID>,
        metricRuleThresholds: [Achievement.Metric.ID: Achievement.ThresholdRule]
    ) -> Self {
        var merged = self
        merged.triggerEvents.formUnion(other.triggerEvents)
        // collapse each record-once trigger to its earliest event
        for triggerID in recordOnceTriggerIDs {
            let events = merged.triggerEvents.filter { $0.triggerId == triggerID }
            guard events.count > 1, let earliest = events.min(by: { $0.timestamp < $1.timestamp }) else {
                continue
            }
            merged.triggerEvents.subtract(events)
            merged.triggerEvents.insert(earliest)
        }
        for (metricId, observation) in other.metricObservations {
            if let rule = metricRuleThresholds[metricId] {
                merged.record(.init(id: metricId, rule: rule), value: observation.value, timestamp: observation.timestamp)
            } else if merged.metricObservations[metricId] == nil {
                // metric this app version doesn't define (e.g. written by a newer build):
                // preserve it verbatim rather than dropping it on write-back
                merged.metricObservations[metricId] = observation
            }
        }
        return merged
    }
    
    fileprivate mutating func record(_ trigger: Achievement.Trigger, timestamp: Date) {
        switch trigger.recordingMode {
        case .recordOnce:
            let hasEvent = triggerEvents.contains { $0.triggerId == trigger.id }
            if !hasEvent {
                fallthrough
            }
        case .keepAll:
            triggerEvents.insert(.init(triggerId: trigger.id, timestamp: timestamp))
        }
    }
    
    fileprivate mutating func record(_ metric: Achievement.Metric, value: Double, timestamp: Date) {
        guard let oldEntry = metricObservations[metric.id] else {
            metricObservations[metric.id] = .init(timestamp: timestamp, value: value)
            return
        }
        switch metric.rule {
        case .atLeast: // tracking upwards: keep the max value, earliest timestamp on a tie
            if value > oldEntry.value || (value == oldEntry.value && timestamp < oldEntry.timestamp) {
                metricObservations[metric.id] = .init(timestamp: timestamp, value: value)
            }
        case .atMost: // tracking downwards: keep the min value, earliest timestamp on a tie
            if value < oldEntry.value || (value == oldEntry.value && timestamp < oldEntry.timestamp) {
                metricObservations[metric.id] = .init(timestamp: timestamp, value: value)
            }
        }
    }
}


// MARK: Querying

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
        switch achievement.kind {
        case let .event(trigger, predicate):
            return predicate(
                achievementsState.triggerEvents
                    .filter { $0.triggerId == trigger.id }
                    .sorted(using: KeyPathComparator(\.timestamp))
            )
        case let .threshold(metric, target):
            guard let observation = achievementsState.metricObservations[metric.id] else {
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
