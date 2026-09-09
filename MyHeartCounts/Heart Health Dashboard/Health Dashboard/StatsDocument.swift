//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation


/// Read-side model of a monthly stats document. Optional merge metadata extends the existing version-zero format.
struct StatsDocument: Decodable, Sendable {
    typealias SourceID = String

    /// Mergeable average components expressed in the entry's unit. Weighting identifies the writer's averaging algorithm.
    /// A writer must omit these fields when it cannot reproduce the exact numerator and denominator of its average.
    struct Average: Codable, Hashable, Sendable {
        let numerator: Double
        let denominator: Double
        let weighting: String

        var isValid: Bool {
            numerator.isFinite && denominator.isFinite && denominator > 0 && !weighting.isEmpty
        }
    }

    struct Entry: Decodable, Sendable {
        var start: String?
        var end: String?
        var sum: Double?
        var min: Double?
        var max: Double?
        var avg: Double?
        var date: String?
        var value: Double?
        var systolic: Double?
        var diastolic: Double?
        let unit: String
        var average: Average?

        /// Empty ranges represent individual observations.
        var timeRange: Range<Date>? {
            if let date = date.flatMap(Self.parseDate), start == nil, end == nil {
                return date..<date
            }
            guard let start = start.flatMap(Self.parseDate), let end = end.flatMap(Self.parseDate), start < end, date == nil else {
                return nil
            }
            return start..<end
        }

        private static func parseDate(_ string: String) -> Date? {
            (try? Date(string, strategy: .iso8601))
                ?? (try? Date(string, strategy: .iso8601.time(includingFractionalSeconds: true)))
        }
    }

    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }

        init(stringValue: String) {
            self.stringValue = stringValue
        }

        init?(intValue: Int) {
            nil
        }
    }

    /// Retains the rest of the month when one entry cannot be decoded.
    private struct LossyEntry: Decodable {
        let entry: Entry?

        init(from decoder: any Decoder) throws {
            entry = try? Entry(from: decoder)
        }
    }

    let version: Int
    let metric: String
    let entriesBySourceId: [SourceID: [Entry]]
    let malformedEntryCount: Int

    init(version: Int = 0, metric: String, entriesBySourceId: [SourceID: [Entry]], malformedEntryCount: Int = 0) {
        self.version = version
        self.metric = metric
        self.entriesBySourceId = entriesBySourceId
        self.malformedEntryCount = malformedEntryCount
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        version = try container.decode(Int.self, forKey: Key(stringValue: "version"))
        metric = try container.decode(String.self, forKey: Key(stringValue: "metric"))
        let entriesKeys = ["hourly", "daily", "sessions", "samples"].filter { container.contains(Key(stringValue: $0)) }
        guard entriesKeys.count == 1 else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Expected exactly one stats entry kind"))
        }
        let entries = try entriesKeys.first.map {
            try container.decode([String: [LossyEntry]].self, forKey: Key(stringValue: $0))
        } ?? [:]
        entriesBySourceId = entries.mapValues { $0.compactMap(\.entry) }
        malformedEntryCount = entries.values.reduce(0) { $0 + $1.filter { $0.entry == nil }.count }
    }
}
