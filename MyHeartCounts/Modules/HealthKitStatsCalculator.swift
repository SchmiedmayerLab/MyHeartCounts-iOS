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
import Synchronization


@Observable
final class HealthKitStatsCalculator: ServiceModule, EnvironmentAccessible, @unchecked Sendable {
    // swiftlint:disable attributes
    @ObservationIgnored @Application(\.logger) private var logger
    @ObservationIgnored @Dependency(HealthKit.self) private var healthKit
    @ObservationIgnored @Dependency(Account.self) private var account
    @ObservationIgnored @Dependency(AccountNotifications.self) private var accountNotifications
    @ObservationIgnored @Dependency(MHCBackgroundTasks.self) private var backgroundTasks
    // swiftlint:enable attributes
    
    /// The currently-active long-lived stats processing task.
    private let task: Mutex<Task<Void, Never>?> = .init(nil)
    
    var isActive: Bool {
        task.withLock { $0 != nil }
    }
    
    func configure() {
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
    
    /// Starts the calculator, unless it is already running.
    ///
    /// - returns: whether this call is the one that started it.
    @discardableResult
    func start() -> Bool {
        task.withLock { task in
            guard task == nil else {
                return false
            }
            task = Task {
                await self._run()
            }
            return true
        }
    }
    
    func stop() {
        task.withLock { task in
            exchange(&task, with: nil)?.cancel()
        }
    }
    
    
    @concurrent
    private func _run() async {
        defer {
            if !Task.isCancelled {
                // should never reach here (the process functions below should all monitor for new data indefinitely),
                // but if we do end up here, we clear out the task just in case
                stop()
            }
        }
        await account.waitForAccountDetailsReady()
        guard let accountId = await account.details?.accountId else {
            logger.error("no accountId")
            return
        }
        guard let enrollmentDate = await account.details?.dateOfEnrollment else {
            logger.error("no enrollment date")
            return
        }
        let accountDoc = FirebaseFirestore.Firestore.firestore().document("/users/\(accountId)")
        await withDiscardingTaskGroup { taskGroup in
            for descriptor in Self.bucketedDescriptors {
                taskGroup.addTask {
                    let months = Self.months(since: enrollmentDate, coverage: descriptor.coverage)
                    await self.process(descriptor, months: months, accountDoc: accountDoc)
                }
            }
            for descriptor in Self.individualSamplesDescriptors {
                taskGroup.addTask {
                    let months = await self.months(since: enrollmentDate, coverage: descriptor.coverage, latestSampleOf: descriptor.sampleType)
                    await self.process(descriptor, months: months, accountDoc: accountDoc)
                }
            }
            for descriptor in NonstandardSamplesRunDescriptor.allCases {
                taskGroup.addTask {
                    let months = Self.months(since: enrollmentDate, coverage: descriptor.coverage)
                    await self.process(descriptor, months: months, accountDoc: accountDoc)
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
        static let heartRate = Self(rawValue: "heart-rate")
        static let weight = Self(rawValue: "weight")
        static let height = Self(rawValue: "height")
        static let bmi = Self(rawValue: "bmi")
        static let sleep = Self("sleep")
        static let bloodPressure = Self("blood-pressure")
        
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
        
        init(year: Int, month: Int, range: Range<Date>) {
            self.year = year
            self.monthString = String(format: "%02d", month)
            self.range = range
        }
    }

    // private but testable
    /// How far back a metric's stats documents reach, independently of when the participant enrolled.
    ///
    /// Sized after the widest window the metric's readers (the CVH score, the dashboard tiles) ask for: without this,
    /// a freshly enrolled participant's dashboard would stay empty for those metrics until enough of the study has passed,
    /// and for slow-moving values such as weight a reading taken shortly before enrolling would never show up at all.
    struct Coverage {
        /// Covers the months since the enrollment, and nothing before that.
        static let sinceEnrollment = Self(precedingMonths: 0)
        
        /// The number of months before the current one that must be covered, regardless of the enrollment date.
        let precedingMonths: Int
        /// Whether the month of the metric's most recent sample must be covered as well, however old that sample is.
        ///
        /// For values that are entered once and then stay valid (height), the readers want the latest sample rather than
        /// a window, so covering a fixed number of months would miss it for everyone whose sample is older than that.
        var includesLatestSample = false
    }
    
    // private but testable
    /// The months a metric's stats should cover: every month from the participant's enrollment up to the current one,
    /// extended backwards so that at least the coverage's preceding months are included as well.
    static func months(
        since enrollmentDate: Date,
        coverage: Coverage,
        now: Date = .now,
        calendar cal: Calendar = .current
    ) -> [StatsMonth] {
        guard enrollmentDate < now else {
            return []
        }
        var firstMonthStart = cal.startOfMonth(for: enrollmentDate)
        if coverage.precedingMonths > 0, let coverageStart = cal.date(byAdding: .month, value: -coverage.precedingMonths, to: now) {
            firstMonthStart = min(firstMonthStart, cal.startOfMonth(for: coverageStart))
        }
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
    
    /// The months an individual-samples metric's stats should cover, additionally including the month of the metric's
    /// most recent sample if its coverage asks for that — however long ago that sample was recorded.
    private func months(
        since enrollmentDate: Date,
        coverage: Coverage,
        latestSampleOf sampleType: SampleType<HKQuantitySample>
    ) async -> [StatsMonth] {
        var months = Self.months(since: enrollmentDate, coverage: coverage)
        guard coverage.includesLatestSample else {
            return months
        }
        do {
            let latestSample = try await healthKit.query(
                sampleType,
                timeRange: .ever,
                limit: 1,
                sortedBy: [SortDescriptor(\.startDate, order: .reverse)]
            ).first
            if let latestSample,
               let month = Self.month(containing: latestSample.startDate),
               !months.contains(where: { $0.documentId == month.documentId }) {
                months.insert(month, at: 0)
            }
        } catch {
            logger.error("Unable to look up the most recent \(sampleType) sample: \(error)")
        }
        return months
    }

    private func writeStatsDocument<Entry: Codable>(
        accountDoc: DocumentReference,
        metricId: MetricID,
        month: StatsMonth,
        entriesKey: MonthlyStatsDocumentEntriesKey,
        entries: [Entry]
    ) async throws {
        guard !Task.isCancelled else {
            return
        }
        guard !entries.isEmpty else {
            // don't touch the doc for months without any data: an empty query result can also mean that
            // HealthKit read authorization was revoked, and we don't want that to wipe existing entries
            return
        }
        // NOTE: writing to this document will mean that we implicitly end up creating an empty document
        // at `users/{uid}/stats/{metricId}`, which won't be queryable (bc it's empty).
        // this isn't a problem, as we currently don't need to query these docs, but we should at least
        // be aware of this being a thing.
        let doc = accountDoc
            .collection("stats")
            .document(metricId.rawValue)
            .collection("months")
            .document(month.documentId)
        do {
            // we first try to update the doc in place.
            // (the explicit cast forces the FirestoreUtils overload, which pre-encodes the entries;
            // the plain Firestore updateData cannot handle Swift structs)
            try await doc.updateData([
                FieldPath([entriesKey.rawValue, DataSourceID.healthKit.rawValue]): entries
            ] as [AnyHashable: any Codable])
        } catch let error as NSError where error.code == FirestoreErrorCode.notFound.rawValue {
            // the document we're tryng to update doesn't exist yet, so we need to create it
            let statsDoc = MonthlyStatsDocument(
                metric: metricId,
                entriesKey: entriesKey,
                entriesBySourceId: [.healthKit: entries]
            )
            try await doc.setData(from: statsDoc)
        }
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
        let coverage: Coverage
    }
    
    private struct IndividualSamplesRunDescriptor {
        let sampleType: SampleType<HKQuantitySample>
        /// the metric's well-known identifier per the data spec; used for the stats doc path and `metric` field. deliberately not the HK identifier.
        let metricId: MetricID
        let coverage: Coverage
    }
    
    private enum NonstandardSamplesRunDescriptor: CaseIterable {
        case sleepSessions
        case bloodPressure
        
        var coverage: Coverage {
            switch self {
            case .sleepSessions:
                // the CVH score reads the last two weeks of sleep sessions
                Coverage(precedingMonths: 1)
            case .bloodPressure:
                // the CVH score reads the last three months of blood pressure readings
                Coverage(precedingMonths: 3)
            }
        }
    }
    
    
    // one run per metric in the spec's Metrics table (docs/MHCDataSpec.md)
    // the bucketed metrics' readers only look back a week, and every covered month gets rewritten in full whenever its
    // statistics change, so these deliberately don't reach back before the enrollment.
    private static let bucketedDescriptors: [StatsRunDescriptor] = [
        .init(
            sampleType: .stepCount,
            metricId: .steps,
            mode: .sum,
            aggregationInterval: .hour,
            entriesKey: .hourly,
            coverage: .sinceEnrollment
        ),
        .init(
            sampleType: .appleExerciseTime,
            metricId: .exerciseTime,
            mode: .sum,
            aggregationInterval: .hour,
            entriesKey: .hourly,
            coverage: .sinceEnrollment
        ),
        .init(
            sampleType: .heartRate,
            metricId: .heartRate,
            mode: .minMaxAvg,
            aggregationInterval: .hour,
            entriesKey: .hourly,
            coverage: .sinceEnrollment
        )
    ]
    
    // the CVH score reads the last three months of weight, the last two weeks of BMI, and the most recent height
    // regardless of its age (adults don't grow, and a height is typically entered once, long before enrolling).
    private static let individualSamplesDescriptors: [IndividualSamplesRunDescriptor] = [
        .init(sampleType: .bodyMass, metricId: .weight, coverage: Coverage(precedingMonths: 3)),
        .init(sampleType: .height, metricId: .height, coverage: Coverage(precedingMonths: 0, includesLatestSample: true)),
        .init(sampleType: .bodyMassIndex, metricId: .bmi, coverage: Coverage(precedingMonths: 1))
    ]
    
    
    private func process( // swiftlint:disable:this function_body_length
        _ input: StatsRunDescriptor,
        months: [StatsMonth],
        accountDoc: DocumentReference
    ) async {
        let unit = input.sampleType.canonicalUnit
        func imp(month: StatsMonth) async throws { // swiftlint:disable:this function_body_length
            let results = try await healthKit.continuousStatisticsQuery(
                input.sampleType,
                options: { () -> HKStatisticsOptions in
                    switch input.mode {
                    case .sum:
                        [.cumulativeSum]
                    case .minMaxAvg:
                        [.discreteMin, .discreteMax, .discreteAverage]
                    }
                }(),
                aggInterval: input.aggregationInterval,
                timeRange: .init(month.range)
            )
            for try await stats in results {
                let stats: [StatEntry] = switch input.mode {
                case .sum:
                    stats.compactMap { stats in
                        guard let sum = stats.sumQuantity() else {
                            return nil
                        }
                        return StatEntry(
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
                        return StatEntry(
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
                try await writeStatsDocument(
                    accountDoc: accountDoc,
                    metricId: input.metricId,
                    month: month,
                    entriesKey: input.entriesKey,
                    entries: stats
                )
            }
        }
        await withDiscardingTaskGroup { taskGroup in
            for month in months {
                taskGroup.addTask {
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
        accountDoc: DocumentReference
    ) async {
        func imp(month: StatsMonth) async throws {
            let unit = input.sampleType.canonicalUnit
            let results = healthKit.continuousQuery(
                input.sampleType,
                timeRange: .init(month.range),
                anchor: queryAnchors[input.sampleType, month]
            )
            for try await result in results {
                defer {
                    queryAnchors[input.sampleType, month] = result.newAnchor
                }
                let samples = try await healthKit.query(input.sampleType, timeRange: .init(month.range))
                let entries = samples.map { sample in
                    QuantitySampleEntry(
                        date: sample.startDate,
                        unit: unit,
                        value: sample.quantity.doubleValue(for: unit)
                    )
                }
                try await writeStatsDocument(
                    accountDoc: accountDoc,
                    metricId: input.metricId,
                    month: month,
                    entriesKey: .samples,
                    entries: entries
                )
            }
        }
        await withDiscardingTaskGroup { taskGroup in
            for month in months {
                taskGroup.addTask {
                    do {
                        try await imp(month: month)
                    } catch {
                        self.logger.error("\(error)")
                    }
                }
            }
        }
    }
    
    
    private func process(_ descriptor: NonstandardSamplesRunDescriptor, months: [StatsMonth], accountDoc: DocumentReference) async {
        switch descriptor {
        case .sleepSessions:
            await runSleepStats(months: months, accountDoc: accountDoc)
        case .bloodPressure:
            await runBloodPressureStats(months: months, accountDoc: accountDoc)
        }
    }
    
    
    @concurrent
    private func runSleepStats(months: [StatsMonth], accountDoc: DocumentReference) async {
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
                defer {
                    queryAnchors[.sleepAnalysis, month] = result.newAnchor
                }
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
                    StatEntry(
                        start: session.startDate,
                        end: session.endDate,
                        unit: .hour(),
                        values: .sum(session.totalTimeSpentAsleep / 60 / 60)
                    )
                }
                try await writeStatsDocument(
                    accountDoc: accountDoc,
                    metricId: .sleep,
                    month: month,
                    entriesKey: .sessions,
                    entries: entries
                )
            }
        }
        await withDiscardingTaskGroup { taskGroup in
            for month in months {
                taskGroup.addTask {
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
    private func runBloodPressureStats(months: [StatsMonth], accountDoc: DocumentReference) async {
        let unit = SampleType.bloodPressureSystolic.canonicalUnit // mmHg
        func imp(month: StatsMonth) async throws {
            let results = self.healthKit.continuousQuery(
                .bloodPressure,
                timeRange: .init(month.range),
                anchor: queryAnchors[.bloodPressure, month]
            )
            for try await result in results {
                defer {
                    queryAnchors[.bloodPressure, month] = result.newAnchor
                }
                let samples = try await self.healthKit.query(.bloodPressure, timeRange: .init(month.range))
                let entries = samples.compactMap { correlation -> BloodPressureSampleEntry? in
                    guard let systolic = correlation.objects(for: .bloodPressureSystolic).first,
                          let diastolic = correlation.objects(for: .bloodPressureDiastolic).first else {
                        return nil
                    }
                    return BloodPressureSampleEntry(
                        date: correlation.startDate,
                        unit: unit,
                        systolic: systolic.quantity.doubleValue(for: unit),
                        diastolic: diastolic.quantity.doubleValue(for: unit)
                    )
                }
                try await writeStatsDocument(
                    accountDoc: accountDoc,
                    metricId: .bloodPressure,
                    month: month,
                    entriesKey: .samples,
                    entries: entries
                )
            }
        }
        await withDiscardingTaskGroup { taskGroup in
            for month in months {
                taskGroup.addTask {
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


// MARK: Wire format

extension HealthKitStatsCalculator {
    fileprivate enum StatsWireFormat {
        /// spec: all timestamps in stats documents are ISO8601 strings; we include the device's local-time UTC offset (matching the bucket boundaries, which are computed in local time).
        /// - Note: the field modifiers must all be spelled out: calling any modifier on an `ISO8601FormatStyle` discards the default field set, so e.g. a bare `.timeZone(separator:)` style would format dates as just the offset.
        static let dateFormat = Date.ISO8601FormatStyle(timeZone: .current)
            .year().month().day() // swiftlint:disable:this multiline_function_chains
            .dateTimeSeparator(.standard)
            .time(includingFractionalSeconds: false)
            .timeZone(separator: .colon)

        static func parseDate(_ string: String) throws -> Date {
            if let date = try? Date(string, strategy: dateFormat) {
                return date
            }
            // tolerate other ISO8601 offset spellings (e.g. "Z", or no colon in the offset)
            return try Date(string, strategy: .iso8601)
        }
    }


    /// A single sum or min/max/avg entry in a bucketed (hourly/daily) single-month stats document
    fileprivate struct StatEntry: Codable {
        enum CodingKeys: String, Swift.CodingKey {
            case start, end, unit, sum, min, max, avg
        }

        enum StatsValues {
            case sum(Double)
            case minMaxAvg(min: Double, max: Double, avg: Double)

            init(from container: KeyedDecodingContainer<CodingKeys>) throws {
                if container.contains(.sum) {
                    self = .sum(try container.decode(Double.self, forKey: .sum))
                } else {
                    let min = try container.decode(Double.self, forKey: .min)
                    let max = try container.decode(Double.self, forKey: .max)
                    let avg = try container.decode(Double.self, forKey: .avg)
                    self = .minMaxAvg(min: min, max: max, avg: avg)
                }
            }

            func encode(to container: inout KeyedEncodingContainer<CodingKeys>) throws {
                switch self {
                case .sum(let sum):
                    try container.encode(sum, forKey: .sum)
                case let .minMaxAvg(min, max, avg):
                    try container.encode(min, forKey: .min)
                    try container.encode(max, forKey: .max)
                    try container.encode(avg, forKey: .avg)
                }
            }
        }

        let start: Date
        let end: Date
        let unit: HKUnit
        let values: StatsValues

        init(start: Date, end: Date, unit: HKUnit, values: StatsValues) {
            self.start = start
            self.end = end
            self.unit = unit
            self.values = values
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.start = try StatsWireFormat.parseDate(container.decode(String.self, forKey: .start))
            self.end = try StatsWireFormat.parseDate(container.decode(String.self, forKey: .end))
            self.unit = try container.decode(HKUnit.self, forKey: .unit)
            self.values = try .init(from: container)
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(start.formatted(StatsWireFormat.dateFormat), forKey: .start)
            try container.encode(end.formatted(StatsWireFormat.dateFormat), forKey: .end)
            try container.encode(unit, forKey: .unit)
            try values.encode(to: &container)
        }
    }


    /// A single reading in an individual-samples single-month stats document
    fileprivate struct QuantitySampleEntry: Codable {
        enum CodingKeys: String, Swift.CodingKey {
            case date, unit, value
        }

        let date: Date
        let unit: HKUnit
        let value: Double

        init(date: Date, unit: HKUnit, value: Double) {
            self.date = date
            self.unit = unit
            self.value = value
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.date = try StatsWireFormat.parseDate(container.decode(String.self, forKey: .date))
            self.unit = try container.decode(HKUnit.self, forKey: .unit)
            self.value = try container.decode(Double.self, forKey: .value)
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(date.formatted(StatsWireFormat.dateFormat), forKey: .date)
            try container.encode(unit, forKey: .unit)
            try container.encode(value, forKey: .value)
        }
    }


    /// A single sys/dia reading pair in the blood-pressure single-month stats document
    fileprivate struct BloodPressureSampleEntry: Codable {
        enum CodingKeys: String, Swift.CodingKey {
            case date, unit, systolic, diastolic
        }

        let date: Date
        let unit: HKUnit
        let systolic: Double
        let diastolic: Double

        init(date: Date, unit: HKUnit, systolic: Double, diastolic: Double) {
            self.date = date
            self.unit = unit
            self.systolic = systolic
            self.diastolic = diastolic
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.date = try StatsWireFormat.parseDate(container.decode(String.self, forKey: .date))
            self.unit = try container.decode(HKUnit.self, forKey: .unit)
            self.systolic = try container.decode(Double.self, forKey: .systolic)
            self.diastolic = try container.decode(Double.self, forKey: .diastolic)
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(date.formatted(StatsWireFormat.dateFormat), forKey: .date)
            try container.encode(unit, forKey: .unit)
            try container.encode(systolic, forKey: .systolic)
            try container.encode(diastolic, forKey: .diastolic)
        }
    }
}


// MARK: Stats document

extension HealthKitStatsCalculator {
    fileprivate enum MonthlyStatsDocumentEntriesKey: String, CaseIterable {
        case hourly, daily, sessions, samples
    }

    fileprivate struct MonthlyStatsDocument<Entry: Codable>: Codable {
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
