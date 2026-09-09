//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import HealthKit
import MyHeartCountsShared


extension StatsDocument {
    private enum EntryCodingKeys: String, CodingKey {
        case start, end, unit, sum, min, max, avg, average, date, value, systolic, diastolic
    }

    private enum WireFormat {
        /// Preserve the writer's whole-second timestamps and the device's local UTC offset.
        /// All fields are explicit because modifiers discard ISO8601FormatStyle's default field set.
        static let dateFormat = Date.ISO8601FormatStyle(timeZone: .current)
            .year().month().day() // swiftlint:disable:this multiline_function_chains
            .dateTimeSeparator(.standard)
            .time(includingFractionalSeconds: false)
            .timeZone(separator: .colon)

        static func parseDate(_ string: String) throws -> Date {
            if let date = try? Date(string, strategy: .iso8601) {
                return date
            }
            return try Date(string, strategy: .iso8601.time(includingFractionalSeconds: true))
        }

        static func requireShape(allowing keys: Set<EntryCodingKeys>, in container: KeyedDecodingContainer<EntryCodingKeys>) throws {
            guard container.allKeys.allSatisfy(keys.contains) else {
                throw DecodingError.dataCorrupted(.init(codingPath: container.codingPath, debugDescription: "Mixed stats entry shapes"))
            }
        }
    }

    /// A sum or min/max/avg bucket, also used for whole sleep sessions.
    struct Aggregate: Codable, Sendable {
        enum Values: Codable, Sendable {
            case sum(Double)
            case minMaxAvg(min: Double, max: Double, avg: Double, average: Average? = nil)

            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: EntryCodingKeys.self)
                if container.contains(.sum) {
                    try WireFormat.requireShape(allowing: [.start, .end, .unit, .sum], in: container)
                    self = .sum(try container.decode(Double.self, forKey: .sum))
                } else {
                    try WireFormat.requireShape(allowing: [.start, .end, .unit, .min, .max, .avg, .average], in: container)
                    self = .minMaxAvg(
                        min: try container.decode(Double.self, forKey: .min),
                        max: try container.decode(Double.self, forKey: .max),
                        avg: try container.decode(Double.self, forKey: .avg),
                        average: try container.decodeIfPresent(Average.self, forKey: .average)
                    )
                }
            }

            func encode(to encoder: any Encoder) throws {
                var container = encoder.container(keyedBy: EntryCodingKeys.self)
                switch self {
                case .sum(let sum):
                    try container.encode(sum, forKey: .sum)
                case let .minMaxAvg(min, max, avg, average):
                    try container.encode(min, forKey: .min)
                    try container.encode(max, forKey: .max)
                    try container.encode(avg, forKey: .avg)
                    try container.encodeIfPresent(average, forKey: .average)
                }
            }
        }

        let start: Date
        let end: Date
        let unit: HKUnit
        let values: Values

        init(start: Date, end: Date, unit: HKUnit, values: Values) {
            self.start = start
            self.end = end
            self.unit = unit
            self.values = values
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: EntryCodingKeys.self)
            start = try WireFormat.parseDate(container.decode(String.self, forKey: .start))
            end = try WireFormat.parseDate(container.decode(String.self, forKey: .end))
            guard start < end else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid stats interval bounds"))
            }
            unit = try container.decode(HKUnit.self, forKey: .unit)
            values = try Values(from: decoder)
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: EntryCodingKeys.self)
            try container.encode(start.formatted(WireFormat.dateFormat), forKey: .start)
            try container.encode(end.formatted(WireFormat.dateFormat), forKey: .end)
            try container.encode(unit, forKey: .unit)
            try values.encode(to: encoder)
        }
    }

    /// One individual quantity reading.
    struct Quantity: Codable, Sendable {
        let date: Date
        let unit: HKUnit
        let value: Double

        init(date: Date, unit: HKUnit, value: Double) {
            self.date = date
            self.unit = unit
            self.value = value
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: EntryCodingKeys.self)
            try WireFormat.requireShape(allowing: [.date, .unit, .value], in: container)
            date = try WireFormat.parseDate(container.decode(String.self, forKey: .date))
            unit = try container.decode(HKUnit.self, forKey: .unit)
            value = try container.decode(Double.self, forKey: .value)
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: EntryCodingKeys.self)
            try container.encode(date.formatted(WireFormat.dateFormat), forKey: .date)
            try container.encode(unit, forKey: .unit)
            try container.encode(value, forKey: .value)
        }
    }

    /// One systolic/diastolic reading pair.
    struct BloodPressure: Codable, Sendable {
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
            let container = try decoder.container(keyedBy: EntryCodingKeys.self)
            try WireFormat.requireShape(allowing: [.date, .unit, .systolic, .diastolic], in: container)
            date = try WireFormat.parseDate(container.decode(String.self, forKey: .date))
            unit = try container.decode(HKUnit.self, forKey: .unit)
            systolic = try container.decode(Double.self, forKey: .systolic)
            diastolic = try container.decode(Double.self, forKey: .diastolic)
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: EntryCodingKeys.self)
            try container.encode(date.formatted(WireFormat.dateFormat), forKey: .date)
            try container.encode(unit, forKey: .unit)
            try container.encode(systolic, forKey: .systolic)
            try container.encode(diastolic, forKey: .diastolic)
        }
    }
}
