//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import HealthKit


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

    /// The same entry payloads are encoded by the HealthKit writer and decoded by stats queries.
    enum Entry: Codable, Sendable {
        case aggregate(Aggregate)
        case quantity(Quantity)
        case bloodPressure(BloodPressure)

        private enum CodingKeys: String, CodingKey {
            case start, end, systolic, diastolic
        }

        var unit: HKUnit {
            switch self {
            case .aggregate(let entry): entry.unit
            case .quantity(let entry): entry.unit
            case .bloodPressure(let entry): entry.unit
            }
        }

        /// Empty ranges represent individual observations.
        var timeRange: Range<Date>? {
            switch self {
            case .aggregate(let entry):
                entry.start < entry.end ? entry.start..<entry.end : nil
            case .quantity(let entry):
                entry.date..<entry.date
            case .bloodPressure(let entry):
                entry.date..<entry.date
            }
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if container.contains(.start) || container.contains(.end) {
                self = .aggregate(try Aggregate(from: decoder))
            } else if container.contains(.systolic) || container.contains(.diastolic) {
                self = .bloodPressure(try BloodPressure(from: decoder))
            } else {
                self = .quantity(try Quantity(from: decoder))
            }
        }

        func encode(to encoder: any Encoder) throws {
            switch self {
            case .aggregate(let entry): try entry.encode(to: encoder)
            case .quantity(let entry): try entry.encode(to: encoder)
            case .bloodPressure(let entry): try entry.encode(to: encoder)
            }
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
