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
final class AchievementsManager: Module, EnvironmentAccessible, @unchecked Sendable { // call it just Achievements?
    struct State: Hashable, Codable, Sendable {
        struct TriggerEvent: Hashable, Codable, Sendable {
            /// The trigger that occurred
            let triggerId: Achievement.Trigger.ID
            /// The timestamp when this trigger occurred
            let timestamp: Date
            
            init(triggerId: Achievement.Trigger.ID, timestamp: Date) {
                self.triggerId = triggerId
                self.timestamp = timestamp.normalizedForFirestore()
            }
            
            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                // we want to route this through the normalizing init
                self.init(
                    triggerId: try container.decode(Achievement.Trigger.ID.self, forKey: .triggerId),
                    timestamp: try container.decode(Date.self, forKey: .timestamp)
                )
            }
        }
        
        
        struct MetricObservation: Hashable, Codable, Sendable {
            /// The timestamp when this value was observed.
            let timestamp: Date
            /// The value that was observed
            let value: Double
            
            init(timestamp: Date, value: Double) {
                self.value = value
                self.timestamp = timestamp.normalizedForFirestore()
            }
            
            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                // we want to route this through the normalizing init
                self.init(
                    timestamp: try container.decode(Date.self, forKey: .timestamp),
                    value: try container.decode(Double.self, forKey: .value)
                )
            }
        }
        
        
        struct AchievementUnlock: Hashable, Codable, Sendable {
            let achievementId: Achievement.ID
            let unlockDate: Date
            
            init(achievementId: Achievement.ID, unlockDate: Date) {
                self.achievementId = achievementId
                self.unlockDate = unlockDate.normalizedForFirestore()
            }
            
            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                // we want to route this through the normalizing init
                self.init(
                    achievementId: try container.decode(Achievement.ID.self, forKey: .achievementId),
                    unlockDate: try container.decode(Date.self, forKey: .unlockDate)
                )
            }
        }
        
        
        struct AchievementUnlocks: Hashable, Codable, Sendable {
            private var storage: [Achievement.ID: Date]
            
            init() {
                storage = [:]
            }
            
            init(from decoder: any Decoder) throws {
                let container = try decoder.singleValueContainer()
                storage = try container.decode([Achievement.ID: Date].self)
                    .mapValues { $0.normalizedForFirestore() }
            }
            
            func encode(to encoder: any Encoder) throws {
                var container = encoder.singleValueContainer()
                try container.encode(storage)
            }
            
            subscript(achievementId: Achievement.ID) -> Date? {
                get {
                    storage[achievementId]
                }
                set {
                    storage[achievementId] = newValue?.normalizedForFirestore()
                }
            }
        }
        
        /// The version of the ``State`` type.
        ///
        /// Used to enable potential future evolution of the type.
        fileprivate let version: UInt
        
        fileprivate var triggerEvents: Set<TriggerEvent>
        
        /// - Note: "metric" here is not referring to the metric system, and rather to the fact that each entry belongs to some metric.
        fileprivate var metricObservations: [Achievement.Metric.ID: MetricObservation]
        
        /// Keeps track of recorded unlock events.
        fileprivate var unlocks: AchievementUnlocks
        
        fileprivate init() {
            version = 1
            triggerEvents = []
            metricObservations = [:]
            unlocks = .init()
        }
        
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let version = try container.decode(UInt.self, forKey: .version)
            switch version {
            case 1:
                self.version = version
                self.triggerEvents = try container.decode(Set<TriggerEvent>.self, forKey: .triggerEvents)
                self.metricObservations = try container.decode([Achievement.Metric.ID: MetricObservation].self, forKey: .metricObservations)
                self.unlocks = try container.decode(AchievementUnlocks.self, forKey: .unlocks)
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .version,
                    in: container,
                    debugDescription: "Unsupported version \(version)"
                )
            }
        }
    }
    
    
    private enum SyncError: Error {
        case notEnrolled
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
    /// Set to `true` whenever local state changes and a sync is scheduled.
    ///
    /// The purpose of this flag is to tell an in-flight sync loop it must run another pass, in order to handle situations where the state is changed while the sync is ongoing.
    @MainActor private var syncDirty = false
    /// Pending debounce timer for a requested-but-not-yet-started sync.
    @MainActor private var debounceTask: Task<Void, Never>?
    /// The task used to observe server-side changes, and respond to them
    @MainActor private var remoteChangesObserver: Task<Void, Never>?
    
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
                throw SyncError.notEnrolled
            }
            return try firebaseConfiguration.userDocumentReference.collection("achievementTracking").document(studyId.uuidString)
        }
    }
    
    
    nonisolated init() {}
    
    
    func configure() {
        Achievement.registerDefaultAchievements(with: self)
        Task {
            do {
                // try to connect the manager w/ the account. this will fail if no user is logged in, in which case we fall back
                // to the association happening when the Standard calls -associateWithAccount in response to the user logging in
                try await self.associateWithAccount()
            } catch {
                logger.error("Setup failed: \(error)")
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
    private func _runSync() async throws { // swiftlint:disable:this function_body_length cyclomatic_complexity
        if let runningSync {
            try await runningSync.value
            return
        }
        /// Performs a single read-merge-write pass against the cloud document
        let syncImpl = { @MainActor () async throws in // swiftlint:disable:this closure_body_length
            let doc: DocumentReference
            do {
                doc = try self.achievementTrackingDoc
            } catch SyncError.notEnrolled {
                // loading the doc failed bc the user is not enrolled.
                // in this case, we intentionally don't want to go down the retry path.
                self.achievementsState = State()
                self.syncDirty = false
                return
            } catch {
                self.syncDirty = true
                throw error
            }
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
            let cloud: State
            do {
                cloud = try snapshot.data(as: State.self)
            } catch {
                self.syncDirty = true
                throw error
            }
            // Fold cloud into the captured local state (least-upper-bound). `merged >= local`, so
            // adopting it never regresses local progress.
            let merged = local.merging(cloud, allAchievements: self.achievements)
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
    
    
    /// Configures the `AchievementsManager` to populate its state from the currently logged-in `Account`
    ///
    /// This function also sets up an observer on the firestore document tracking the current user's achievements progress, and automatically syncs any remote changes back into the local state.
    ///
    /// This function only performs actual work the first time is called; any subsequent calls will see that an association already exists and return early.
    /// Call  ``disassociateFromAccount()`` to clear the association (e.g., in response to user logout), in which case the next call to this function will set up a new one.
    @MainActor
    func associateWithAccount() async throws {
        guard remoteChangesObserver == nil else {
            return
        }
        let doc = try achievementTrackingDoc
        let snapshots = doc.snapshots
        remoteChangesObserver = Task {
            defer {
                self.remoteChangesObserver = nil
            }
            do {
                for try await snapshot: DocumentSnapshot in snapshots {
                    guard !snapshot.metadata.hasPendingWrites else {
                        // if `snapshot.metadata.hasPendingWrites` is true, we're being informed about a client-side mutation
                        // (which obv we want to skip)
                        continue
                    }
                    do {
                        try await syncNow()
                    } catch {
                        logger.error("Sync in response to remote doc update failed: \(error)")
                    }
                }
            } catch {
                self.logger.error("Remote changes observation failed: \(error)")
            }
        }
        try await refresh()
    }
    
    
    /// Cancels the association set up by ``associateWithAccount()`` and clears the local achievments state.
    ///
    /// - Important: you very likely want to perform a final sync (``syncNow()``) before calling this function, to ensure the local state is correctly persisted in the cloud.
    ///     This function will cancel all pending debounces and all in-progress syncs!
    @MainActor
    func disassociateFromAccount() {
        func cancel(_ task: inout Task<some Any, some Any>?) {
            task?.cancel()
            task = nil
        }
        cancel(&remoteChangesObserver)
        cancel(&debounceTask)
        cancel(&runningSync)
        achievementsState = .init()
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
        // Note that `numDays` here intentionally differs from `num{Weeks|Months|Years}` in that it starts counting at 1 instead of 0.
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
        await withDiscardingTaskGroup { taskGroup in
            let queryTimeRange = HealthKitQueryTimeRange(Calendar.current.startOfDay(for: enrollmentDate)..<Date.now)
            taskGroup.addTask {
                for stats in (try? await self.healthKit.statisticsQuery(
                    .stepCount,
                    aggregatedBy: [.sum],
                    over: .day,
                    timeRange: queryTimeRange
                )) ?? [] {
                    guard let stepCount = stats.sumQuantity()?.doubleValue(for: .count()) else {
                        continue
                    }
                    await self.record(
                        .dailyStepCount,
                        value: stepCount,
                        // using start of day here.
                        timestamp: stats.timeRange.lowerBound
                    )
                }
            }
            taskGroup.addTask {
                guard let ecgs = try? await self.healthKit.query(.electrocardiogram, timeRange: queryTimeRange), !ecgs.isEmpty else {
                    return
                }
                // SAFETY: we know that `ecgs` has at least one element, so `max(of:)` will never be nil.
                let newestECGDate = ecgs.max(of: \.endDate)! // swiftlint:disable:this force_unwrapping
                await self.record(.numRecordedECGs, value: ecgs.count, timestamp: newestECGDate)
            }
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
        achievementsState.record(metric, value: value, timestamp: timestamp, allAchievements: achievements)
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
    ///
    /// - parameter recordOnceTriggerIDs: all currently-known trigger ids whose rule is ``Achievement/Trigger/RecordingMode/recordOnce``.
    /// - parameter metricRuleThresholds: the currently-registered metric rule thresholds.
    fileprivate func merging(
        _ other: Self,
//        recordOnceTriggerIDs: Set<Achievement.Trigger.ID>,
//        metricRuleThresholds: [Achievement.Metric.ID: Achievement.ThresholdRule],
        allAchievements: some Collection<Achievement>
    ) -> Self {
        /// Trigger IDs whose events collapse to a single (earliest) entry when merging two states.
        let recordOnceTriggerIds: Set<Achievement.Trigger.ID> = allAchievements.reduce(into: []) { result, achievement in
            switch achievement.kind {
            case .event(let trigger, predicate: _):
                if trigger.recordingMode == .recordOnce {
                    result.insert(trigger.id)
                }
            case .threshold:
                break
            }
        }
        /// Metric rules by metric id
        let metricRuleThresholds: [Achievement.Metric.ID: Achievement.ThresholdRule] = allAchievements.reduce(into: [:]) { result, achievement in
            switch achievement.kind {
            case .threshold(let metric, target: _):
                result[metric.id] = metric.rule
            case .event:
                break
            }
        }
        var merged = self
        merged.triggerEvents.formUnion(other.triggerEvents)
        // collapse each record-once trigger to its earliest event
        for triggerID in recordOnceTriggerIds {
            let events = merged.triggerEvents.filter { $0.triggerId == triggerID }
            guard events.count > 1, let earliest = events.min(by: { $0.timestamp < $1.timestamp }) else {
                continue
            }
            merged.triggerEvents.subtract(events)
            merged.triggerEvents.insert(earliest)
        }
        for (metricId, observation) in other.metricObservations {
            if let rule = metricRuleThresholds[metricId] {
                merged.record(
                    .init(id: metricId, rule: rule),
                    value: observation.value,
                    timestamp: observation.timestamp,
                    allAchievements: allAchievements
                )
            } else {
                // unknown metric (likely written by server / other build, and we're currently running an outdated version of the app)
                if let currentValue = merged.metricObservations[metricId] {
                    // the observation exists in self, and in other.
                    // this presents us with a problem w.r.t. the question of how this should be handled
                    // (the issue being that we don't have the definition so we don't know how to reduce these 2 observations into 1)...
                    // TODO
                } else { // present in other but not in self
                    // the observation is present in the incoming State, but not in the destination one.
                    // we simply preserve it as-is.
                    merged.metricObservations[metricId] = observation
                }
            }
        }
        return merged
    }
    
    fileprivate mutating func record(_ trigger: Achievement.Trigger, timestamp: Date) {
        switch trigger.recordingMode {
        case .recordOnce:
            if let idx = triggerEvents.firstIndex(where: { $0.triggerId == trigger.id }) {
                if timestamp < triggerEvents[idx].timestamp {
                    triggerEvents.remove(at: idx)
                    fallthrough
                }
            } else {
                fallthrough
            }
        case .keepAll:
            triggerEvents.insert(.init(triggerId: trigger.id, timestamp: timestamp))
        }
    }
    
    fileprivate mutating func record(
        _ metric: Achievement.Metric,
        value: Double,
        timestamp: Date,
        allAchievements: some Collection<Achievement>
    ) {
        guard let oldEntry = metricObservations[metric.id] else {
            metricObservations[metric.id] = .init(timestamp: timestamp, value: value)
            evaluateUnlocks(trigger: .updatedMetricObservation(metric: metric), allAchievements: allAchievements)
            return
        }
        switch metric.rule {
        case .atLeast: // tracking upwards: keep the max value, earliest timestamp on a tie
            if value > oldEntry.value || (value == oldEntry.value && timestamp < oldEntry.timestamp) {
                metricObservations[metric.id] = .init(timestamp: timestamp, value: value)
                evaluateUnlocks(trigger: .updatedMetricObservation(metric: metric), allAchievements: allAchievements)
            }
        case .atMost: // tracking downwards: keep the min value, earliest timestamp on a tie
            if value < oldEntry.value || (value == oldEntry.value && timestamp < oldEntry.timestamp) {
                metricObservations[metric.id] = .init(timestamp: timestamp, value: value)
                evaluateUnlocks(trigger: .updatedMetricObservation(metric: metric), allAchievements: allAchievements)
            }
        }
    }
    
    
    fileprivate func state(of achievement: Achievement) -> AchievementsManager.AchievementState {
        if let unlockDate = unlocks[achievement.id] {
            return .unlocked(unlockDate: unlockDate)
        }
        switch achievement.kind {
        case let .event(trigger, predicate):
            return predicate(
                triggerEvents
                    .filter { $0.triggerId == trigger.id }
                    .sorted(using: KeyPathComparator(\.timestamp))
            )
        case let .threshold(metric, target):
            guard let observation = metricObservations[metric.id] else {
                return .locked(progress: 0, lastUpdate: nil)
            }
            let progress: Double = switch metric.rule {
            case .atLeast(let base): // tracking upwards
                if let base {
                    ((observation.value - base) / (target - base)).clamped(to: 0...1)
                } else {
                    (observation.value >= target) ? 1 : 0
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


extension AchievementsManager.State {
    /// Info about the specific thing that caused the evaluation to be performed.
    private enum UnlocksEvalTrigger {
        case updatedMetricObservation(metric: Achievement.Metric)
        case unknown
    }
    
    private mutating func evaluateUnlocks(
        trigger: UnlocksEvalTrigger,
        allAchievements: some Collection<Achievement>
    ) {
        for achievement in allAchievements {
            switch achievement.kind {
            case .event:
                // currently not covered by `AchievementUnlocks`.
                break
            case .threshold(let metric, _):
                switch trigger {
                case .updatedMetricObservation(let updatedMetric):
                    guard metric == updatedMetric else {
                        continue
                    }
                case .unknown:
                    break
                }
                guard self.unlocks[achievement.id] == nil else {
                    // already unlocked
                    break
                }
                switch state(of: achievement) {
                case .locked:
                    // still unlocked
                    break
                case .unlocked(let unlockDate):
                    // previously locked, now unlocked
                    unlocks[achievement.id] = unlockDate
                }
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
    ) -> UpcomingAchievement? {
        nextLockedAchievements(in: category).first {
            AchievementsFilter.category(category, subcategory: subcategory).evaluate($0.achievement)
        }
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
        achievementsState.state(of: achievement)
    }
}


extension Date {
    /// Creates a new date value by normalizing (rounding) this date in a way that will make it resilient to Firestore decoding/encoding round trips.
    func normalizedForFirestore() -> Date {
        Date(timeIntervalSinceReferenceDate: timeIntervalSinceReferenceDate.rounded(toNearestMultipleOf: 0x1p-3)) // 1 * 2^-3
    }
}


extension FloatingPoint {
    func rounded(toNearestMultipleOf step: Self, rule: FloatingPointRoundingRule = .toNearestOrAwayFromZero) -> Self {
        (self / step).rounded(rule) * step
    }
}
