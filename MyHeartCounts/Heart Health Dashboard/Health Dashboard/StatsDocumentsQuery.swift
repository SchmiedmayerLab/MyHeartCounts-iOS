//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

// swiftlint:disable type_contents_order

import FirebaseFirestore
import Foundation
import HealthKit
import MyHeartCountsShared
import OSLog
import SpeziAccount
import SpeziFoundation
import SpeziHealthKit
import SpeziHealthKitUI
import SwiftUI


/// Fetches the entries of a metric's server-side stats documents.
///
/// This is the read-side counterpart to ``HealthKitStatsCalculator``: it observes the metric's
/// `users/{uid}/stats/{metricId}/months` collection (restricted to the months overlapping the query's time range),
/// decodes the monthly documents, and flattens their entries into a chronologically sorted list of elements.
///
/// - Note: the resolution of the returned entries is whatever the stats documents store (e.g. hourly buckets);
///     consumers that need coarser aggregates can re-aggregate via `reducedIntoIntervals(using:over:anchor:overallTimeRange:calendar:)`.
@MainActor
@propertyWrapper
struct StatsDocumentsQuery<Element: Sendable>: DynamicProperty {
    typealias MetricID = HealthKitStatsCalculator.MetricID
    
    private struct StatsDocDecoder: MyHeartCountsShared::ValueTransformer {
        private struct Failure: Error {}
        
        let metricId: HealthKitStatsCalculator.MetricID
        
        func transform(_ input: QueryDocumentSnapshot) throws -> StatsDocument {
            let logger = Logger(category: .init("StatsDocumentsQuery"))
            let statsDoc: StatsDocument
            do {
                statsDoc = try input.data(as: StatsDocument.self)
            } catch {
                logger.error("unable to decode stats document at '\(input.reference.path)': \(error)")
                throw error
            }
            switch statsDoc.version {
            case 0:
                guard statsDoc.metric == metricId.rawValue else {
                    logger.error(
                        "skipping stats document at '\(input.reference.path)': its metric field ('\(statsDoc.metric)') doesn't match the queried metric ('\(metricId.rawValue)')"
                    )
                    throw Failure()
                }
                return statsDoc
            default:
                logger.error("skipping stats document at '\(input.reference.path)' with unsupported version \(statsDoc.version)")
                throw Failure()
            }
        }
    }
    
    /// The underlying query, fetching one `[Element]` chunk per month document.
    ///
    /// The month documents overlapping the time range are what the listener follows; the time range's finer-grained
    /// filtering of their entries is done in the decode step, which the query redoes over the documents it already has
    /// whenever the parameters change — so a view changing its time range never re-queries months it already holds.
    @MHCFirestoreQuery<[Element]> private var monthChunks: [[Element]]
    private let areInIncreasingOrder: @Sendable (Element, Element) -> Bool
    
    var wrappedValue: [Element] {
        // NOTE: this flattens+sorts on every access (rather than once per snapshot);
        // fine at the amounts of data involved here.
        monthChunks.flatMap { $0 }.sorted(by: areInIncreasingOrder)
    }
    
    fileprivate init(
        metricId: MetricID,
        timeRange: HealthKitQueryTimeRange,
        transform: some MyHeartCountsShared.ValueTransformer<StatsDocument, [Element]>,
        areInIncreasingOrder: @escaping @Sendable (Element, Element) -> Bool
    ) {
        self.areInIncreasingOrder = areInIncreasingOrder
        let timeRange = timeRange.range
        // matches nothing; used when the time range doesn't overlap any month that could contain data
        let bounds = Self.monthDocumentIdBounds(for: timeRange) ?? "0000-00"..."0000-00"
        self._monthChunks = MHCFirestoreQuery(
            [Element].self,
            collection: .user(path: "stats/\(metricId.rawValue)/months"),
            filter: .documentId(in: bounds),
            decoder: StatsDocDecoder(metricId: metricId).concat(transform)
        )
    }
    
    /// The `yyyy-MM` document-id bounds of the months overlapping the time range.
    ///
    /// Since the (zero-padded) month document ids sort lexicographically in chronologic order, these can be used
    /// to restrict the query to the relevant months via a `FieldPath.documentID()` range filter.
    /// `nil` if the time range doesn't overlap any month that could contain data.
    private static func monthDocumentIdBounds(for timeRange: Range<Date>) -> ClosedRange<String>? {
        let cal = Calendar.current
        func monthId(for date: Date, addingMonths offset: Int) -> String? {
            guard let date = cal.date(byAdding: .month, value: offset, to: date) else {
                return nil
            }
            let components = cal.dateComponents([.year, .month], from: date)
            guard let year = components.year, let month = components.month else {
                return nil
            }
            return String(format: "%04d-%02d", year, month)
        }
        // the month a document is filed under is determined by the *writer's* time zone at computation time;
        // widening the bounds by one month on either end makes sure we don't miss entries near a month boundary.
        // (the upper bound is additionally clamped to the current date: no stats documents exist for future months,
        // which also handles open-ended time ranges, whose upper bound is `.distantFuture`.)
        guard let lowerBound = monthId(for: timeRange.lowerBound, addingMonths: -1),
              let upperBound = monthId(for: min(timeRange.upperBound, .now), addingMonths: 1),
              lowerBound <= upperBound else {
            return nil
        }
        return lowerBound...upperBound
    }
}


extension StatsDocumentsQuery where Element == QuantitySample {
    private struct QuantitySampleDecoder: MyHeartCountsShared::ValueTransformer {
        let metric: HealthStatsMetric
        let timeRange: Range<Date>
        let aggregationKind: StatisticsAggregationOption
        
        func transform(_ input: StatsDocument) throws -> [QuantitySample] {
            input.quantitySamples(for: metric, in: timeRange, aggregationKind: aggregationKind)
        }
    }
    
    /// - parameter metric: the metric whose stats documents should be fetched
    /// - parameter timeRange: the time range to fetch entries for
    /// - parameter aggregationKind: which of a bucketed entry's values (sum, resp. min/max/avg) should be used as the resulting sample's value.
    ///     (Individual-samples entries carry only a single value, and ignore this.)
    init(metric: HealthStatsMetric, timeRange: HealthKitQueryTimeRange, aggregationKind: StatisticsAggregationOption) {
        self.init(
            metricId: metric.id,
            timeRange: timeRange,
            transform: QuantitySampleDecoder(metric: metric, timeRange: timeRange.range, aggregationKind: aggregationKind),
            areInIncreasingOrder: { $0.startDate < $1.startDate }
        )
    }
}


extension StatsDocumentsQuery where Element == SleepSessionStatsSample {
    private struct SleepSessionsDecoder: MyHeartCountsShared::ValueTransformer {
        let timeRange: Range<Date>
        
        func transform(_ input: StatsDocument) throws -> [SleepSessionStatsSample] {
            input.sleepSessionSamples(in: timeRange)
        }
    }
    
    /// Fetches the sleep sessions of the `sleep` metric's stats documents.
    /// (Sleep isn't a quantity sample type, so it doesn't have a ``HealthStatsMetric``.)
    init(sleepSessionsIn timeRange: HealthKitQueryTimeRange) {
        self.init(
            metricId: .sleep,
            timeRange: timeRange,
            transform: SleepSessionsDecoder(timeRange: timeRange.range),
            areInIncreasingOrder: { $0.timeRange.upperBound < $1.timeRange.upperBound }
        )
    }
}


extension StatsDocumentsQuery where Element == BloodPressureStatsSample {
    private struct BloodPressureDecoder: MyHeartCountsShared::ValueTransformer {
        let timeRange: Range<Date>
        
        func transform(_ input: StatsDocument) throws -> [BloodPressureStatsSample] {
            input.bloodPressureSamples(in: timeRange)
        }
    }
    
    /// Fetches the sys/dia reading pairs of the `blood-pressure` metric's stats documents.
    /// (Blood pressure isn't representable as ``QuantitySample``s, since its entries carry two values.)
    init(bloodPressureIn timeRange: HealthKitQueryTimeRange) {
        self.init(
            metricId: .bloodPressure,
            timeRange: timeRange,
            transform: BloodPressureDecoder(timeRange: timeRange.range),
            areInIncreasingOrder: { $0.date < $1.date }
        )
    }
}


// MARK: Document Decoding

extension StatsDocumentsQuery {
    /// Read-side model of a monthly stats document, as written by ``HealthKitStatsCalculator`` (see `docs/MHCDataSpec.md`).
    fileprivate struct StatsDocument: Decodable, Sendable {
        /// The keys under which a stats document can store its entries (grouped by data source).
        /// A document is expected to use exactly one of these; if multiple are present, the first match wins.
        static var entriesKeys: [String] { ["hourly", "daily", "sessions", "samples"] }
        
        let version: Int
        let metric: String
        /// the entries, keyed by data-source identifier (e.g. `com.apple.HealthKit`).
        let entriesBySourceId: [String: [Entry]]
        
        private struct CodingKey: Swift.CodingKey {
            let stringValue: String
            var intValue: Int? { nil }
            
            init(stringValue: String) {
                self.stringValue = stringValue
            }
            init?(intValue: Int) {
                nil
            }
        }
        
        /// Wrapper that turns an undecodable element into `nil` instead of failing the containing array.
        /// (We don't want a single malformed entry to discard an entire month of data.)
        private struct LossyEntry: Decodable {
            let entry: Entry?
            
            init(from decoder: any Decoder) throws {
                entry = try? Entry(from: decoder)
            }
        }
        
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKey.self)
            version = try container.decode(Int.self, forKey: .init(stringValue: "version"))
            metric = try container.decode(String.self, forKey: .init(stringValue: "metric"))
            var entriesBySourceId: [String: [Entry]] = [:]
            for entriesKey in Self.entriesKeys {
                guard let entries = try container.decodeIfPresent([String: [LossyEntry]].self, forKey: .init(stringValue: entriesKey)) else {
                    continue
                }
                entriesBySourceId = entries.mapValues { $0.compactMap(\.entry) }
                break
            }
            self.entriesBySourceId = entriesBySourceId
        }
        
        /// The entries of the document's preferred data source.
        ///
        /// NOTE: the spec models the sources within a stats document as *competing* (e.g., HealthKit and a wearable
        /// integration both covering the same hours), so we must pick one source rather than combine them
        /// (summing entries from two sources covering the same time period would double-count).
        /// For the time being, we prefer HealthKit-derived entries, and otherwise simply use the source with the most entries.
        var preferredSourceEntries: [Entry] {
            entriesBySourceId["com.apple.HealthKit"]
                ?? entriesBySourceId.max { $0.value.count < $1.value.count }?.value
                ?? []
        }
        
        func quantitySamples(
            for metric: HealthStatsMetric,
            in timeRange: Range<Date>,
            aggregationKind: StatisticsAggregationOption
        ) -> [QuantitySample] {
            preferredSourceEntries.compactMap { entry in
                entry.quantitySample(for: metric, in: timeRange, aggregationKind: aggregationKind)
            }
        }
        
        func bloodPressureSamples(in timeRange: Range<Date>) -> [BloodPressureStatsSample] {
            preferredSourceEntries.compactMap { entry in
                entry.bloodPressureSample(in: timeRange)
            }
        }
        
        func sleepSessionSamples(in timeRange: Range<Date>) -> [SleepSessionStatsSample] {
            preferredSourceEntries.compactMap { entry in
                entry.sleepSessionSample(in: timeRange)
            }
        }
    }
    
    
    /// A single entry within a stats document.
    ///
    /// This intentionally models the union of the different entry shapes (bucketed sum, bucketed min/max/avg, individual sample),
    /// so that we can decode all of them with a single type.
    fileprivate struct Entry: Decodable, Sendable {
        // bucketed entries
        let start: String?
        let end: String?
        let sum: Double?
        let min: Double?
        let max: Double?
        let avg: Double?
        // individual-sample entries
        let date: String?
        let value: Double?
        // blood-pressure entries
        let systolic: Double?
        let diastolic: Double?
        // all entries
        let unit: String
        
        /// The time range the entry covers. Empty (`lowerBound == upperBound`) for individual-sample entries.
        var timeRange: Range<Date>? {
            if let start = start.flatMap(Self.parseDate), let end = end.flatMap(Self.parseDate), start <= end {
                start..<end
            } else if let date = date.flatMap(Self.parseDate) {
                date..<date
            } else {
                nil
            }
        }
        
        func quantitySample(
            for metric: HealthStatsMetric,
            in timeRange: Range<Date>,
            aggregationKind: StatisticsAggregationOption
        ) -> QuantitySample? {
            guard let entryTimeRange = self.timeRange,
                  let unit = HKUnit.parse(self.unit),
                  let value = self.value(for: aggregationKind) else {
                return nil
            }
            let overlaps = entryTimeRange.isEmpty
                ? timeRange.contains(entryTimeRange.lowerBound)
                : timeRange.overlaps(entryTimeRange)
            guard overlaps else {
                return nil
            }
            let quantity = HKQuantity(unit: unit, doubleValue: value)
            guard quantity.is(compatibleWith: metric.sampleType.canonicalUnit) else {
                // an entry with a unit that's dimensionally incompatible with the metric's sample type
                // (converting would raise an unrecoverable NSException); skip it
                return nil
            }
            return QuantitySample(
                id: UUID(),
                sampleType: .healthKit(metric.sampleType),
                quantity: quantity,
                startDate: entryTimeRange.lowerBound,
                endDate: entryTimeRange.upperBound
            )
        }
        
        func sleepSessionSample(in timeRange: Range<Date>) -> SleepSessionStatsSample? {
            guard let entryTimeRange = self.timeRange,
                  let sum,
                  let unit = HKUnit.parse(self.unit),
                  timeRange.overlaps(entryTimeRange) else {
                return nil
            }
            let quantity = HKQuantity(unit: unit, doubleValue: sum)
            guard quantity.is(compatibleWith: .hour()) else {
                return nil
            }
            return SleepSessionStatsSample(timeRange: entryTimeRange, hoursAsleep: quantity.doubleValue(for: .hour()))
        }
        
        func bloodPressureSample(in timeRange: Range<Date>) -> BloodPressureStatsSample? {
            guard let entryTimeRange = self.timeRange,
                  let systolic,
                  let diastolic,
                  timeRange.contains(entryTimeRange.lowerBound) else {
                return nil
            }
            return BloodPressureStatsSample(date: entryTimeRange.lowerBound, systolic: systolic, diastolic: diastolic)
        }
        
        /// - Note: bucketed entries only carry the values their aggregation produced (e.g. a steps entry only has `sum`);
        ///     requesting an aggregation kind the entry doesn't carry yields `nil`, and the entry is skipped.
        func value(for aggregationKind: StatisticsAggregationOption) -> Double? {
            if let value {
                return value
            }
            return switch aggregationKind {
            case .sum: sum
            case .avg: avg
            case .min: min
            case .max: max
            }
        }
        
        private static func parseDate(_ string: String) -> Date? {
            if let date = try? Date(string, strategy: dateFormat) {
                date
            } else {
                // tolerate other ISO8601 offset spellings (e.g. "Z", or no colon in the offset)
                try? Date(string, strategy: .iso8601)
            }
        }
        
        private static var dateFormat: Date.ISO8601FormatStyle {
            Date.ISO8601FormatStyle(timeZone: .current)
                .year().month().day() // swiftlint:disable:this multiline_function_chains
                .dateTimeSeparator(.standard)
                .time(includingFractionalSeconds: false)
                .timeZone(separator: .colon)
        }
    }
}
