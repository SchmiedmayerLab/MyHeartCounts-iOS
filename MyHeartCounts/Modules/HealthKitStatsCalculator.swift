//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

// swiftlint:disable file_length

import FirebaseFirestore
import Foundation
import HealthKit
import MyHeartCountsShared
import OSLog
import Spezi
import SpeziAccount
import SpeziFirestore
import SpeziFoundation
import SpeziHealthKit
import SwiftUI
import Synchronization
import UIKit


@Observable
final class HealthKitStatsCalculator: ServiceModule, EnvironmentAccessible, @unchecked Sendable {
    private struct Run {
        let id: UUID
        var month: DateComponents
        let task: Task<Void, Never>
        var needsRestart = false
    }

    // swiftlint:disable attributes
    @ObservationIgnored @Application(\.logger) private var logger
    @ObservationIgnored @Dependency(HealthKit.self) private var healthKit
    @ObservationIgnored @Dependency(Account.self) private var account
    @ObservationIgnored @Dependency(AccountNotifications.self) private var accountNotifications
    @ObservationIgnored @Dependency(MHCBackgroundTasks.self) private var backgroundTasks
    @ObservationIgnored @Dependency(Lifecycle.self) private var lifecycle
    // swiftlint:enable attributes
    
    /// The active run, or its canceled task while shutdown is finishing.
    private let currentRun: Mutex<Run?> = .init(nil)
    
    /// Whether calculation is enabled, including while waiting for a network connection.
    var isActive: Bool {
        currentRun.withLock { $0.map { !$0.task.isCancelled } ?? false }
    }
    
    func configure() {
        lifecycle.onChange(of: \.scenePhase) { [weak self] oldValue, newValue in
            if oldValue != .active, newValue == .active {
                self?.refreshIfNeeded()
            }
        }
        do {
            try backgroundTasks.register(.healthResearch(
                id: .healthStatsRefresh,
                nextTriggerDate: .after(TimeConstants.hour * 12),
                options: [.requiresNetworkConnectivity],
                protectionTypeOfRequiredData: .complete
            ) {
                // rather crude but since we're using anchor-based live updating queries below
                // and would like to avoid having to add a second non-live-query-based implementation,
                // simply starting the module, giving it a couple of seconds to do its work and then
                // stopping it again seems like the best approach.
                // If the module is already running (e.g. because the task fired into a process that also has
                // a foreground session), we only lend it our execution time and leave it running afterwards.
                let didStart = self.start()
                defer {
                    if didStart {
                        self.stop()
                    }
                }
                try await Task.sleep(for: .seconds(20))
            })
        } catch {
            logger.error("failed to register bg task: \(error)")
        }
    }

    // run when the app is actually launched in foreground.
    // NOT run during background launches, which is ok.
    func run() async {
        if await account.details != nil {
            // currently already signed in. issue here is that the account events don't replay,
            // so if the initial `associatedAccount` event fired before this module's `run()`
            // function was called we'd miss it.
            start()
        }
        for await event in accountNotifications.events {
            switch event {
            case .associatedAccount:
                start()
            case .disassociatingAccount:
                stop()
                queryAnchors.resetAll()
            case .detailsChanged, .deletingAccount:
                break
            }
        }
    }
    
    /// Starts the calculator, or replaces a run whose month changed or whose queries exited.
    ///
    /// - returns: whether this call is the one that started it.
    @discardableResult
    func start() -> Bool {
        currentRun.withLock { start(&$0) }
    }
    
    func stop() {
        // Retain the task until it finishes so a later start can wait for its writes and queries to stop.
        currentRun.withLock { $0?.task.cancel() }
    }

    private func refreshIfNeeded() {
        currentRun.withLock { run in
            guard run?.task.isCancelled == false else {
                return
            }
            _ = start(&run)
        }
    }

    private func restartIfMonthChanged(runId: UUID) {
        currentRun.withLock { run in
            let month = Calendar.current.dateComponents([.era, .year, .month], from: .now)
            guard run?.id == runId, run?.task.isCancelled == false, run?.month != month else {
                return
            }
            run?.needsRestart = true
            _ = start(&run)
        }
    }

    private func start(_ run: inout Run?) -> Bool {
        let now = Date.now
        let calendar = Calendar.current
        let month = calendar.dateComponents([.era, .year, .month], from: now)
        let wasActive = run.map { !$0.task.isCancelled } ?? false
        guard !wasActive || run?.month != month || run?.needsRestart == true else {
            return false
        }
        let previousTask = run?.task
        previousTask?.cancel()
        let id = UUID()
        let task = Task {
            defer {
                self.currentRun.withLock { run in
                    if run?.id == id {
                        run = nil
                    }
                }
            }
            // Finish the previous run before starting queries that could write the same stats documents.
            await previousTask?.value
            guard !Task.isCancelled else {
                return
            }
            await self.runWhenConnected(id: id)
        }
        run = Run(id: id, month: month, task: task)
        // Refreshing an existing run does not transfer ownership to a background caller.
        return !wasActive
    }

    private func workerDidExit(runId: UUID) {
        currentRun.withLock { run in
            if !Task.isCancelled, run?.id == runId {
                run?.needsRestart = true
            }
        }
    }

    private func commitStatsAnchor(runId: UUID, _ commit: () -> Void) {
        currentRun.withLock { run in
            // Serialize anchor updates with stop/logout so a finishing write cannot undo an anchor reset.
            guard !Task.isCancelled, run?.id == runId, run?.task.isCancelled == false else {
                return
            }
            commit()
        }
    }

    @concurrent
    func runQueries(id: UUID) async {
        // The connection monitor outlives this attempt. Allow enroll/foreground refresh to retry an early exit.
        defer { workerDidExit(runId: id) }
        await account.waitForAccountDetailsReady()
        guard !Task.isCancelled else {
            return
        }
        guard let accountId = await account.details?.accountId else {
            logger.error("no accountId")
            return
        }
        guard let enrollmentDate = await account.details?.dateOfEnrollment, enrollmentDate < .now else {
            logger.error("no enrollment date")
            return
        }
        let accountDoc = FirebaseFirestore.Firestore.firestore().document("/users/\(accountId)")
        let writer = FirestoreStatsWriter(accountDoc: accountDoc)
        do {
            // Cancellation cannot retract writes already queued by Firestore. Drain them before a new run
            // submits more, including after reconnects and app restarts while the backend is unreachable.
            try await writer.waitForPendingWrites()
        } catch {
            if !Task.isCancelled {
                logger.error("Unable to finish pending Firestore writes: \(error)")
            }
            return
        }
        await processMetrics(since: enrollmentDate, persistence: StatsPersistence(writer: writer), runId: id)
    }

    private func processMetrics(since enrollmentDate: Date, persistence: StatsPersistence, runId id: UUID) async {
        guard !Task.isCancelled else {
            return
        }
        // A run can spend days waiting for connectivity or pending writes. Select its months only now.
        let now = Date.now
        let calendar = Calendar.current
        let months = Self.months(since: enrollmentDate, now: now, calendar: calendar)
        currentRun.withLock { run in
            if run?.id == id {
                run?.month = calendar.dateComponents([.era, .year, .month], from: now)
                run?.needsRestart = false
            }
        }
        await withDiscardingTaskGroup { taskGroup in
            taskGroup.addTask {
                for await _ in NotificationCenter.default.notifications(named: UIApplication.significantTimeChangeNotification) {
                    self.restartIfMonthChanged(runId: id)
                }
            }
            for descriptor in Self.bucketedDescriptors {
                taskGroup.addTask {
                    await self.process(descriptor, months: months, persistence: persistence, runId: id)
                }
            }
            for descriptor in Self.individualSamplesDescriptors {
                taskGroup.addTask {
                    let individualMonths = await self.months(for: descriptor, extending: months, calendar: calendar, runId: id)
                    await self.process(descriptor, months: individualMonths, persistence: persistence, runId: id)
                }
            }
            for descriptor in NonstandardSamplesRunDescriptor.allCases {
                taskGroup.addTask {
                    await self.process(descriptor, months: months, persistence: persistence, runId: id)
                }
            }
        }
    }
}


extension MHCBackgroundTasks.TaskIdentifier {
    static let healthStatsRefresh = Self("edu.stanford.MyHeartCounts.healthStatsRefresh")
}


extension HealthKitStatsCalculator {
    /* private but testable */ struct QueryAnchors {
        // Since the API doesn't support nesting yet
        // (needs to be added in Grove, but since MHC hasn't yet done the Spezi -> Grove migration, we wouldn't be able to use it),
        // we instead hardcode the effective, nested, namespace.
        // This namespace nesting allows us to be able to both delete all entries for these query anchors, while also still be able
        // to to a scoped bulk-delete of all MHC entries.
        static let namespace: LocalPreferenceKeys.Namespace = .custom("edu.stanford.MyHeartCounts:HealthKitStatsCalcQueryAnchors")
        
        private let prefs = LocalPreferencesStore.standard
        
        fileprivate init() {}
        
        private func prefKey(_ sampleType: SampleType<some Any>, _ month: StatsMonth) -> LocalPreferenceKey<QueryAnchor?> {
            .init(.init("\(sampleType.id)_\(month.documentId)", in: Self.namespace), default: nil)
        }
        
        fileprivate func resetAll() {
            prefs.removeAllEntries(in: Self.namespace)
        }
        
        fileprivate subscript(sampleType: SampleType<some Any>, month: StatsMonth) -> QueryAnchor {
            get { prefs[prefKey(sampleType, month)] ?? .init() }
            nonmutating set { prefs[prefKey(sampleType, month)] = newValue }
        }
    }
    
    private var queryAnchors: QueryAnchors {
        QueryAnchors()
    }
}


// MARK: Types

extension HealthKitStatsCalculator {
    protocol _IDType: RawRepresentable<String>, LosslessStringConvertible, Hashable, Codable, CodingKeyRepresentable, Sendable { // swiftlint:disable:this type_name line_length
        var rawValue: String { get }
        init(rawValue: String)
    }
    
    struct DataSourceID: _IDType {
        static let healthKit = Self(rawValue: "com.apple.HealthKit")
        
        let rawValue: String
    }
    
    
    struct MetricID: _IDType {
        static let steps = Self(rawValue: "steps")
        static let exerciseTime = Self(rawValue: "exercise-time")
        static let activeEnergy = Self(rawValue: "active-energy")
        static let walkingRunningDistance = Self(rawValue: "walking-running-distance")
        static let flightsClimbed = Self(rawValue: "flights-climbed")
        static let heartRate = Self(rawValue: "heart-rate")
        static let restingHeartRate = Self(rawValue: "resting-heart-rate")
        static let weight = Self(rawValue: "weight")
        static let height = Self(rawValue: "height")
        static let bmi = Self(rawValue: "bmi")
        static let sleep = Self("sleep")
        static let bloodPressure = Self("blood-pressure")
        static let workouts = Self("workouts")
        static let electrocardiograms = Self("electrocardiograms")
        
        let rawValue: String
    }
}


extension HealthKitStatsCalculator._IDType {
    var description: String {
        rawValue
    }
    init(_ description: String) {
        self.init(rawValue: description)
    }
}

// Making these `CodingKeyRepresentable` means that we can use them as Dictionary keys and still get regular `key: value`
// mappings as the encoded output; otherwise a dictionary `[key1: value1, key2: value2, ...]` would get turned into an array
// of `[key1, value1, key2, value2, ...]` entries.
extension HealthKitStatsCalculator._IDType {
    var codingKey: any Swift.CodingKey {
        AnyCodingKey(stringValue: rawValue)
    }
    
    init?(codingKey: some Swift.CodingKey) {
        self.init(rawValue: codingKey.stringValue)
    }
}


// MARK: Month iteration & document writing

extension HealthKitStatsCalculator {
    /* private but testable */ struct StatsMonth {
        let year: Int
        let monthString: String // zero-padded
        
        /// The id of the month's stats document (within the metric's `months` subcollection), e.g. `2026-08`.
        /// Zero-padded so that the ids' lexicographic order matches their chronologic order.
        var documentId: String {
            "\(year)-\(monthString)"
        }
        let range: Range<Date>

        /// Include samples crossing either boundary; HealthKit aggregates them into time buckets.
        var overlappingSamplesPredicate: NSPredicate {
            HKQuery.predicateForSamples(withStart: range.lowerBound, end: range.upperBound, options: [])
        }

        /// Individual readings are stored at their start date, so each reading belongs to exactly one month.
        var samplesStartingInMonthPredicate: NSPredicate {
            HKQuery.predicateForSamples(withStart: range.lowerBound, end: range.upperBound, options: .strictStartDate)
        }
        
        init(year: Int, month: Int, range: Range<Date>) {
            self.year = year
            self.monthString = String(format: "%02d", month)
            self.range = range
        }

        func statisticsQuery(
            for sampleType: HKQuantityType,
            options: HKStatisticsOptions,
            intervalComponents: DateComponents
        ) -> HKStatisticsCollectionQueryDescriptor {
            // Spezi's time-range wrapper requires both sample endpoints to be inside the month.
            // Use a native descriptor to select overlapping samples while keeping the month as the bucket anchor.
            HKStatisticsCollectionQueryDescriptor(
                predicate: .quantitySample(type: sampleType, predicate: overlappingSamplesPredicate),
                options: options,
                anchorDate: range.lowerBound,
                intervalComponents: intervalComponents
            )
        }
    }

    // private but testable
    /// The stats history to maintain for app and server consumers: all enrollment months, with at least twelve months of history.
    ///
    /// Starts at the earlier of the enrollment month and the month containing twelve months before the end of today.
    /// Participants enrolled longer ago retain live updates for their full enrollment history.
    static func months(
        since enrollmentDate: Date,
        now: Date = .now,
        calendar cal: Calendar = .current
    ) -> [StatsMonth] {
        let end = cal.startOfNextDay(for: now)
        guard let start = cal.date(byAdding: .month, value: -12, to: end) else {
            return []
        }
        let firstMonthStart = min(cal.startOfMonth(for: enrollmentDate), cal.startOfMonth(for: start))
        return cal
            .dates(
                byAdding: .month,
                value: 1,
                startingAt: firstMonthStart,
                in: firstMonthStart..<cal.startOfNextMonth(for: now)
            )
            // NOTE: the sequence returned by `Calendar.dates(byAdding:)` begins at `start` + 1 interval,
            // i.e. it never yields the start date itself; hence the explicit prepending.
            .chaining(after: CollectionOfOne(firstMonthStart))
            .compactMap { Self.month(containing: $0, calendar: cal) }
    }
    
    // private but testable
    /// The month containing `date`.
    static func month(containing date: Date, calendar cal: Calendar = .current) -> StatsMonth? {
        let monthStart = cal.startOfMonth(for: date)
        let components = cal.dateComponents([.year, .month], from: monthStart)
        guard let year = components.year, let month = components.month else {
            return nil
        }
        let upperBound = cal.startOfNextMonth(for: monthStart)
        guard monthStart < upperBound else {
            return nil
        }
        return StatsMonth(year: year, month: month, range: monthStart..<upperBound)
    }

    /// Height also covers the month of its latest measurement, however long ago it was recorded.
    private func months(
        for descriptor: IndividualSamplesRunDescriptor,
        extending months: [StatsMonth],
        calendar: Calendar,
        runId: UUID
    ) async -> [StatsMonth] {
        guard descriptor.sampleType == .height else {
            return months
        }
        var months = months
        do {
            let latestSample = try await healthKit.query(
                descriptor.sampleType,
                timeRange: .ever,
                limit: 1,
                sortedBy: [SortDescriptor(\.startDate, order: .reverse)]
            ).first
            if let latestSample,
               let month = Self.month(containing: latestSample.startDate, calendar: calendar),
               !months.contains(where: { $0.documentId == month.documentId }) {
                months.insert(month, at: 0)
            }
        } catch {
            logger.error("Unable to look up the most recent \(descriptor.sampleType) sample: \(error)")
            workerDidExit(runId: runId)
        }
        return months
    }
}


// MARK: Bucketed quantity metrics (hourly/daily sums resp. min/max/avg)

extension HealthKitStatsCalculator {
    private enum AggregationMode {
        case sum
        case minMaxAvg
    }

    private struct StatsRunDescriptor {
        let sampleType: SampleType<HKQuantitySample>
        /// the metric's well-known identifier per the data spec; used for the stats doc path and `metric` field. deliberately not the HK identifier.
        let metricId: MetricID
        let mode: AggregationMode
        let aggregationInterval: HealthKit.AggregationInterval
        let entriesKey: MonthlyStatsDocumentEntriesKey
    }
    
    private struct IndividualSamplesRunDescriptor {
        let sampleType: SampleType<HKQuantitySample>
        /// the metric's well-known identifier per the data spec; used for the stats doc path and `metric` field. deliberately not the HK identifier.
        let metricId: MetricID
    }

    private struct EventSamplesRunDescriptor<Sample: _HKSampleWithSampleType, Entry: Codable & Sendable> {
        let sampleType: SampleType<Sample>
        let metricId: MetricID
        let entry: @Sendable (Sample) -> Entry
    }
    
    private enum NonstandardSamplesRunDescriptor: CaseIterable {
        case sleepSessions
        case bloodPressure
        case workouts
        case electrocardiograms
    }
    
    
    // One run per bucketed quantity metric in the spec's Metrics table (docs/MHCDataSpec.md).
    private static let bucketedDescriptors: [StatsRunDescriptor] = [
        .init(
            sampleType: .stepCount,
            metricId: .steps,
            mode: .sum,
            aggregationInterval: .hour,
            entriesKey: .hourly
        ),
        .init(
            sampleType: .appleExerciseTime,
            metricId: .exerciseTime,
            mode: .sum,
            aggregationInterval: .hour,
            entriesKey: .hourly
        ),
        .init(
            sampleType: .activeEnergyBurned,
            metricId: .activeEnergy,
            mode: .sum,
            aggregationInterval: .hour,
            entriesKey: .hourly
        ),
        .init(
            sampleType: .distanceWalkingRunning,
            metricId: .walkingRunningDistance,
            mode: .sum,
            aggregationInterval: .hour,
            entriesKey: .hourly
        ),
        .init(
            sampleType: .flightsClimbed,
            metricId: .flightsClimbed,
            mode: .sum,
            aggregationInterval: .hour,
            entriesKey: .hourly
        ),
        .init(
            sampleType: .heartRate,
            metricId: .heartRate,
            mode: .minMaxAvg,
            aggregationInterval: .hour,
            entriesKey: .hourly
        )
    ]
    
    private static let individualSamplesDescriptors: [IndividualSamplesRunDescriptor] = [
        .init(sampleType: .bodyMass, metricId: .weight),
        .init(sampleType: .height, metricId: .height),
        .init(sampleType: .bodyMassIndex, metricId: .bmi),
        .init(sampleType: .restingHeartRate, metricId: .restingHeartRate)
    ]
    
    
    private func process( // swiftlint:disable:this function_body_length
        _ input: StatsRunDescriptor,
        months: [StatsMonth],
        persistence: StatsPersistence,
        runId: UUID
    ) async {
        let unit = input.sampleType.canonicalUnit
        @concurrent
        func imp(month: StatsMonth) async throws { // swiftlint:disable:this function_body_length
            let query = month.statisticsQuery(
                for: input.sampleType.hkSampleType,
                options: { () -> HKStatisticsOptions in
                    switch input.mode {
                    case .sum:
                        [.cumulativeSum]
                    case .minMaxAvg:
                        [.discreteMin, .discreteMax, .discreteAverage]
                    }
                }(),
                intervalComponents: input.aggregationInterval.intervalComponents
            )
            let results = query.results(for: healthKit.healthStore)
            for try await _ in results {
                // Statistics updates contain no deletion information. A one-record probe establishes/advances an
                // anchor without loading the month's raw samples. Always reread the aggregate after the probe:
                // a queued statistics payload may predate a deletion that this probe is about to acknowledge.
                var anchor = queryAnchors[input.sampleType, month]
                let changes = try await healthKit.query(
                    input.sampleType, timeRange: .ever, anchor: &anchor, limit: 1, predicate: month.overlappingSamplesPredicate
                )
                let collection = try await query.result(for: healthKit.healthStore)
                // An overlapping sample can produce buckets on both sides of the boundary. Store each bucket
                // only in its own month, leaving HealthKit to aggregate samples and reconcile their sources.
                let stats = collection.statistics().filter { month.range.contains($0.startDate) }
                let entries: [StatsDocument.Aggregate] = switch input.mode {
                case .sum:
                    stats.compactMap { stats in
                        guard let sum = stats.sumQuantity() else {
                            return nil
                        }
                        return StatsDocument.Aggregate(
                            start: stats.startDate,
                            end: stats.endDate,
                            unit: unit,
                            values: .sum(sum.doubleValue(for: unit))
                        )
                    }
                case .minMaxAvg:
                    stats.compactMap { stats in
                        guard let min = stats.minimumQuantity(),
                              let max = stats.maximumQuantity(),
                              let avg = stats.averageQuantity() else {
                            return nil
                        }
                        // Heart rate uses HealthKit's temporally weighted average. Neither the public
                        // statistics API nor duration() supplies its averaging denominator, so we must not
                        // manufacture merge weights from sample count, bucket length, or covered duration.
                        return StatsDocument.Aggregate(
                            start: stats.startDate,
                            end: stats.endDate,
                            unit: unit,
                            values: .minMaxAvg(
                                min: min.doubleValue(for: unit),
                                max: max.doubleValue(for: unit),
                                avg: avg.doubleValue(for: unit)
                            )
                        )
                    }
                }
                try await persistence.persistStatsUpdate(
                    entries,
                    for: .init(metricId: input.metricId, month: month, entriesKey: input.entriesKey),
                    hasDeletions: !changes.deleted.isEmpty && changes.added.isEmpty,
                    commitAnchor: { self.commitStatsAnchor(runId: runId) { self.queryAnchors[input.sampleType, month] = anchor } }
                )
            }
        }
        await withDiscardingTaskGroup { taskGroup in
            for month in months {
                taskGroup.addTask {
                    defer { self.workerDidExit(runId: runId) }
                    do {
                        try await imp(month: month)
                    } catch {
                        self.logger.error("Continuous stats processing failed: \(error)")
                    }
                }
            }
        }
    }
    
    
    private func process(
        _ input: IndividualSamplesRunDescriptor,
        months: [StatsMonth],
        persistence: StatsPersistence,
        runId: UUID
    ) async {
        func imp(month: StatsMonth) async throws {
            let unit = input.sampleType.canonicalUnit
            let results = healthKit.continuousQuery(
                input.sampleType,
                timeRange: .ever,
                anchor: queryAnchors[input.sampleType, month],
                predicate: month.samplesStartingInMonthPredicate
            )
            for try await result in results {
                let samples = try await healthKit.query(input.sampleType, timeRange: .ever, predicate: month.samplesStartingInMonthPredicate)
                let entries = samples.map { sample in
                    StatsDocument.Quantity(
                        date: sample.startDate,
                        unit: unit,
                        value: sample.quantity.doubleValue(for: unit)
                    )
                }
                try await persistence.persistStatsUpdate(
                    entries,
                    for: .init(metricId: input.metricId, month: month, entriesKey: .samples),
                    hasDeletions: !result.deletedObjects.isEmpty,
                    commitAnchor: { self.commitStatsAnchor(runId: runId) { self.queryAnchors[input.sampleType, month] = result.newAnchor } }
                )
            }
        }
        await withDiscardingTaskGroup { taskGroup in
            for month in months {
                taskGroup.addTask {
                    defer { self.workerDidExit(runId: runId) }
                    do {
                        try await imp(month: month)
                    } catch {
                        self.logger.error("\(error)")
                    }
                }
            }
        }
    }
    
    
    private func process(_ descriptor: NonstandardSamplesRunDescriptor, months: [StatsMonth], persistence: StatsPersistence, runId: UUID) async {
        switch descriptor {
        case .sleepSessions:
            await runSleepStats(months: months, persistence: persistence, runId: runId)
        case .bloodPressure:
            await runBloodPressureStats(months: months, persistence: persistence, runId: runId)
        case .workouts:
            await process(
                EventSamplesRunDescriptor(sampleType: .workout, metricId: .workouts, entry: StatsDocument.Workout.init(workout:)),
                months: months,
                persistence: persistence,
                runId: runId
            )
        case .electrocardiograms:
            await process(
                EventSamplesRunDescriptor(
                    sampleType: .electrocardiogram, metricId: .electrocardiograms, entry: StatsDocument.Electrocardiogram.init(electrocardiogram:)
                ),
                months: months,
                persistence: persistence,
                runId: runId
            )
        }
    }

    private func process<Sample, Entry>(
        _ descriptor: EventSamplesRunDescriptor<Sample, Entry>,
        months: [StatsMonth],
        persistence: StatsPersistence,
        runId: UUID
    ) async {
        func imp(month: StatsMonth) async throws {
            let results = healthKit.continuousQuery(
                descriptor.sampleType,
                timeRange: .ever,
                anchor: queryAnchors[descriptor.sampleType, month],
                predicate: month.samplesStartingInMonthPredicate
            )
            for try await result in results {
                // Reread the full month so replacements and deletions never accumulate duplicate events.
                let samples = try await healthKit.query(
                    descriptor.sampleType, timeRange: .ever, predicate: month.samplesStartingInMonthPredicate
                )
                try await persistence.persistStatsUpdate(
                    samples.map(descriptor.entry),
                    for: .init(metricId: descriptor.metricId, month: month, entriesKey: .samples),
                    hasDeletions: !result.deletedObjects.isEmpty,
                    commitAnchor: { self.commitStatsAnchor(runId: runId) { self.queryAnchors[descriptor.sampleType, month] = result.newAnchor } }
                )
            }
        }
        await withDiscardingTaskGroup { taskGroup in
            for month in months {
                taskGroup.addTask {
                    defer { self.workerDidExit(runId: runId) }
                    do {
                        try await imp(month: month)
                    } catch {
                        self.logger.error("\(error)")
                    }
                }
            }
        }
    }
    
    
    @concurrent
    private func runSleepStats(months: [StatsMonth], persistence: StatsPersistence, runId: UUID) async {
        func imp(month: StatsMonth) async throws {
            // query with a ±1 day margin: sleep sessions typically span midnight, and the underlying HK
            // predicate only matches samples that both start AND end inside the range, which would
            // otherwise drop the sessions at the month boundaries
            let paddedRange = month.range.lowerBound.addingTimeInterval(-86400)..<month.range.upperBound.addingTimeInterval(86400)
            let results = try await healthKit.continuousQuery(
                .sleepAnalysis,
                timeRange: .init(paddedRange),
                anchor: queryAnchors[.sleepAnalysis, month],
                source: CVHScore.sleepDataSourceFilter
            )
            for try await result in results {
                let samples = try await healthKit.query(
                    .sleepAnalysis,
                    timeRange: .init(paddedRange),
                    source: CVHScore.sleepDataSourceFilter
                )
                // group the samples into sleep sessions, and keep the sessions belonging to this month.
                // this matches how the dashboard used to turn sleep samples into the values it displays;
                // in particular, `totalTimeSpentAsleep` accounts for overlapping samples (e.g. from a phone and a watch
                // both tracking the same night), which we'd otherwise be double-counting.
                let sessions = try samples.splitIntoSleepSessions().filter { session in
                    month.range.contains(session.timeRange.middle)
                }
                let entries = sessions.map { session in
                    StatsDocument.Aggregate(
                        start: session.startDate,
                        end: session.endDate,
                        unit: .hour(),
                        values: .sum(session.totalTimeSpentAsleep / 60 / 60)
                    )
                }
                try await persistence.persistStatsUpdate(
                    entries,
                    for: .init(metricId: .sleep, month: month, entriesKey: .sessions),
                    hasDeletions: !result.deletedObjects.isEmpty,
                    commitAnchor: { self.commitStatsAnchor(runId: runId) { self.queryAnchors[.sleepAnalysis, month] = result.newAnchor } }
                )
            }
        }
        await withDiscardingTaskGroup { taskGroup in
            for month in months {
                taskGroup.addTask {
                    defer { self.workerDidExit(runId: runId) }
                    do {
                        try await imp(month: month)
                    } catch {
                        self.logger.error("\(error)")
                    }
                }
            }
        }
    }
    
    @concurrent
    private func runBloodPressureStats(months: [StatsMonth], persistence: StatsPersistence, runId: UUID) async {
        let unit = SampleType.bloodPressureSystolic.canonicalUnit // mmHg
        func imp(month: StatsMonth) async throws {
            let results = self.healthKit.continuousQuery(
                .bloodPressure,
                timeRange: .ever,
                anchor: queryAnchors[.bloodPressure, month],
                predicate: month.samplesStartingInMonthPredicate
            )
            for try await result in results {
                let samples = try await self.healthKit.query(.bloodPressure, timeRange: .ever, predicate: month.samplesStartingInMonthPredicate)
                let entries = samples.compactMap { correlation -> StatsDocument.BloodPressure? in
                    guard let systolic = correlation.objects(for: .bloodPressureSystolic).first,
                          let diastolic = correlation.objects(for: .bloodPressureDiastolic).first else {
                        return nil
                    }
                    return StatsDocument.BloodPressure(
                        date: correlation.startDate,
                        unit: unit,
                        systolic: systolic.quantity.doubleValue(for: unit),
                        diastolic: diastolic.quantity.doubleValue(for: unit)
                    )
                }
                try await persistence.persistStatsUpdate(
                    entries,
                    for: .init(metricId: .bloodPressure, month: month, entriesKey: .samples),
                    hasDeletions: !result.deletedObjects.isEmpty,
                    commitAnchor: { self.commitStatsAnchor(runId: runId) { self.queryAnchors[.bloodPressure, month] = result.newAnchor } }
                )
            }
        }
        await withDiscardingTaskGroup { taskGroup in
            for month in months {
                taskGroup.addTask {
                    defer { self.workerDidExit(runId: runId) }
                    do {
                        try await imp(month: month)
                    } catch {
                        self.logger.error("\(error)")
                    }
                }
            }
        }
    }
}


// MARK: Stats document

extension HealthKitStatsCalculator {
    enum MonthlyStatsDocumentEntriesKey: String, CaseIterable {
        case hourly, daily, sessions, samples
    }

    struct MonthlyStatsDocument<Entry: Codable>: Codable {
        private struct CodingKey: Swift.CodingKey {
            fileprivate static var version: Self { Self(stringValue: "version") }
            fileprivate static var metric: Self { Self(stringValue: "metric") }

            let stringValue: String
            var intValue: Int? { nil }

            init(stringValue: String) {
                self.stringValue = stringValue
            }
            init?(intValue: Int) {
                nil
            }
        }

        var version: Int
        var metric: MetricID
        var entriesKey: MonthlyStatsDocumentEntriesKey
        var entriesBySourceId: [DataSourceID: [Entry]]

        init(
            metric: MetricID,
            entriesKey: MonthlyStatsDocumentEntriesKey,
            entriesBySourceId: [DataSourceID: [Entry]]
        ) {
            self.version = 0
            self.metric = metric
            self.entriesKey = entriesKey
            self.entriesBySourceId = entriesBySourceId
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKey.self)
            version = try container.decode(Int.self, forKey: .version)
            metric = try container.decode(MetricID.self, forKey: .metric)
            let entriesByKey: [MonthlyStatsDocumentEntriesKey: [DataSourceID: [Entry]]] = try MonthlyStatsDocumentEntriesKey.allCases.reduce(
                into: [:]
            ) { result, entriesKey in
                if let entries = try container.decodeIfPresent(
                    [DataSourceID: [Entry]].self,
                    forKey: CodingKey(stringValue: entriesKey.rawValue)
                ) {
                    result[entriesKey] = entries
                }
            }
            guard let entry = entriesByKey.first else { // there should be at least one entry
                let allAllowedKeys = MonthlyStatsDocumentEntriesKey.allCases.map { "'\($0.rawValue)'" }.sorted()
                throw DecodingError.dataCorrupted(.init(
                    codingPath: [],
                    debugDescription: "Expected exactly 1 entry; got none. (Expected one of \(allAllowedKeys))"
                ))
            }
            guard entriesByKey.count == 1 else { // and there should not be any additional entries
                let parsedEntryKeys = entriesByKey.keys.map { "'\($0.rawValue)'" }.sorted()
                throw DecodingError.dataCorrupted(.init(
                    codingPath: [],
                    debugDescription: "Expected exactly 1 entry; got \(entriesByKey.count) (\(parsedEntryKeys))"
                ))
            }
            (entriesKey, entriesBySourceId) = entry
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKey.self)
            try container.encode(version, forKey: .version)
            try container.encode(metric, forKey: .metric)
            try container.encode(entriesBySourceId, forKey: .init(stringValue: entriesKey.rawValue))
        }
    }
}


extension HKCorrelation {
    func objects<T>(for sampleType: SampleType<T>) -> Set<T> {
        self.objects(for: sampleType.hkSampleType) as? Set<T> ?? []
    }
}
