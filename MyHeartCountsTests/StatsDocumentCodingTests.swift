//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import FirebaseFirestore
import Foundation
import HealthKit
@testable import MyHeartCounts
import Testing


@Suite
struct StatsDocumentCodingTests {
    private let source = "com.apple.HealthKit"
    private let start = Date(timeIntervalSince1970: 0)
    private let end = Date(timeIntervalSince1970: 3600)

    @Test
    func aggregateSumPayloadUsesTheExistingFlatFormat() throws {
        let payload = StatsDocument.Aggregate(start: start, end: end, unit: .count(), values: .sum(123))
        let data = try encode(payload)
        let object = try Firestore.Encoder().encode(payload)
        #expect(Set(object.keys) == ["start", "end", "unit", "sum"])
        #expect(object["unit"] as? String == "count")
        #expect(object["sum"] as? Double == 123)

        let document = try monthlyDocument([object], kind: "hourly", metric: "steps")
        let entry = try #require(document.entriesBySourceId[source]?.first)
        guard case let .aggregate(decoded) = entry, case let .sum(amount) = decoded.values else {
            Issue.record("Expected the writer's sum payload to decode as an aggregate sum")
            return
        }
        #expect(document.malformedEntryCount == 0)
        #expect(decoded.start == start)
        #expect(decoded.end == end)
        #expect(decoded.unit == .count())
        #expect(amount == 123)
        #expect(try encode(entry) == data)
    }

    @Test(arguments: [nil, StatsDocument.Average(numerator: 2250, denominator: 30, weighting: "test.observation-mean.v1")])
    func aggregateAveragesRetainOptionalWeights(average: StatsDocument.Average?) throws {
        let unit = HKUnit.count().unitDivided(by: .minute())
        let payload = StatsDocument.Aggregate(
            start: start,
            end: end,
            unit: unit,
            values: .minMaxAvg(min: 60, max: 100, avg: 75, average: average)
        )
        let data = try encode(payload)
        let object = try Firestore.Encoder().encode(payload)
        let expectedKeys: Set<String> = ["start", "end", "unit", "min", "max", "avg"]
        #expect(Set(object.keys) == expectedKeys.union(average == nil ? [] : ["average"]))

        let document = try monthlyDocument([object], kind: "hourly", metric: "heart-rate")
        let entry = try #require(document.entriesBySourceId[source]?.first)
        guard case let .aggregate(decoded) = entry,
              case let .minMaxAvg(minimum, maximum, mean, decodedAverage) = decoded.values else {
            Issue.record("Expected the writer's min/max/avg payload to decode as an aggregate average")
            return
        }
        #expect(document.malformedEntryCount == 0)
        #expect(decoded.start == start)
        #expect(decoded.end == end)
        #expect(decoded.unit == unit)
        #expect(minimum == 60)
        #expect(maximum == 100)
        #expect(mean == 75)
        #expect(decodedAverage == average)
        #expect(try encode(entry) == data)
    }

    @Test
    func quantityPayloadUsesTheExistingFlatFormat() throws {
        let unit = HKUnit.gramUnit(with: .kilo)
        let payload = StatsDocument.Quantity(date: start, unit: unit, value: 72.5)
        let data = try encode(payload)
        let object = try jsonObject(data)
        #expect(Set(object.keys) == ["date", "unit", "value"])
        #expect(object["unit"] as? String == "kg")
        #expect(object["value"] as? Double == 72.5)

        let document = try monthlyDocument([object], kind: "samples", metric: "weight")
        let entry = try #require(document.entriesBySourceId[source]?.first)
        guard case let .quantity(decoded) = entry else {
            Issue.record("Expected the writer's quantity payload to decode as a quantity")
            return
        }
        #expect(document.malformedEntryCount == 0)
        #expect(decoded.date == start)
        #expect(decoded.unit == unit)
        #expect(decoded.value == 72.5)
        #expect(try encode(entry) == data)
    }

    @Test
    func bloodPressurePayloadUsesTheExistingFlatFormat() throws {
        let unit = HKUnit.millimeterOfMercury()
        let payload = StatsDocument.BloodPressure(date: start, unit: unit, systolic: 120, diastolic: 80)
        let data = try encode(payload)
        let object = try jsonObject(data)
        #expect(Set(object.keys) == ["date", "unit", "systolic", "diastolic"])
        #expect(object["unit"] as? String == "mmHg")
        #expect(object["systolic"] as? Double == 120)
        #expect(object["diastolic"] as? Double == 80)

        let document = try monthlyDocument([object], kind: "samples", metric: "blood-pressure")
        let entry = try #require(document.entriesBySourceId[source]?.first)
        guard case let .bloodPressure(decoded) = entry else {
            Issue.record("Expected the writer's blood-pressure payload to decode as a blood-pressure pair")
            return
        }
        #expect(document.malformedEntryCount == 0)
        #expect(decoded.date == start)
        #expect(decoded.unit == unit)
        #expect(decoded.systolic == 120)
        #expect(decoded.diastolic == 80)
        #expect(try encode(entry) == data)
    }

    @Test(arguments: [
        #"{"start":"1970-01-01T01:00:00.125+01:00","end":"1970-01-01T01:00:00.625+01:00","unit":"count","sum":100,"futureMetadata":{"version":1}}"#,
        #"{"date":"1970-01-01T00:00:00.125Z","unit":"kg","value":70,"futureMetadata":{"version":1}}"#,
        #"{"date":"1970-01-01T00:00:00.125Z","unit":"mmHg","systolic":120,"diastolic":80,"futureMetadata":{"version":1}}"#
    ])
    func legacyFlatEntriesPreserveFractionalInstantsAndIgnoreUnknownFields(json: String) throws {
        let entry = try JSONDecoder().decode(StatsDocument.Entry.self, from: Data(json.utf8))
        let expectedDate = Date(timeIntervalSince1970: 0.125)
        switch entry {
        case .aggregate(let value):
            #expect(value.start == expectedDate)
            #expect(value.end == Date(timeIntervalSince1970: 0.625))
        case .quantity(let value):
            #expect(value.date == expectedDate)
            #expect(value.value == 70)
        case .bloodPressure(let value):
            #expect(value.date == expectedDate)
            #expect(value.systolic == 120)
            #expect(value.diastolic == 80)
        case .workout, .electrocardiogram:
            Issue.record("Expected a non-event stats entry")
        }
    }

    @Test
    func malformedObservationsDoNotDiscardValidSiblings() throws {
        let json = #"""
        {"version":0,"metric":"weight","samples":{"com.apple.HealthKit":[
          {"date":"1970-01-01T00:00:00Z","unit":"kg","value":70},
          {"date":"1970-01-01T00:00:00Z","unit":"kg","value":99,"systolic":120,"diastolic":80},
          {"date":"1970-01-01T00:00:00Z","unit":"kg"},
          {"date":"1970-01-01T00:00:00Z","unit":"invalid-unit","value":99},
          {"date":"1970-01-01T00:00:00Z","unit":"mmHg","systolic":120},
          {"date":"1970-01-01T01:00:00Z","unit":"kg","value":71}
        ]}}
        """#
        let document = try JSONDecoder().decode(StatsDocument.self, from: Data(json.utf8))
        let entries = try #require(document.entriesBySourceId[source])
        #expect(document.malformedEntryCount == 4)
        #expect(entries.count == 2)
        let amounts = entries.compactMap { entry -> Double? in
            guard case let .quantity(quantity) = entry else {
                return nil
            }
            return quantity.value
        }
        #expect(amounts == [70, 71])
    }

    @Test
    func malformedAggregatesDoNotDiscardValidSiblings() throws {
        let json = #"""
        {"version":0,"metric":"steps","hourly":{"com.apple.HealthKit":[
          {"start":"1970-01-01T00:00:00Z","end":"1970-01-01T01:00:00Z","unit":"count","sum":100},
          {"start":"1970-01-01T00:00:00Z","end":"1970-01-01T01:00:00Z","unit":"count","sum":100,"min":60,"max":100,"avg":75},
          {"start":"1970-01-01T00:00:00Z","end":"1970-01-01T01:00:00Z","unit":"count","min":60,"avg":75},
          {"start":"1970-01-01T01:00:00Z","end":"1970-01-01T00:00:00Z","unit":"count","sum":99},
          {"start":"1970-01-01T00:00:00Z","end":"1970-01-01T00:00:00Z","unit":"count","sum":99}
        ]}}
        """#
        let document = try JSONDecoder().decode(StatsDocument.self, from: Data(json.utf8))
        let entries = try #require(document.entriesBySourceId[source])
        #expect(document.malformedEntryCount == 4)
        #expect(entries.count == 1)
        guard case let .aggregate(aggregate) = try #require(entries.first), case let .sum(amount) = aggregate.values else {
            Issue.record("Expected the valid aggregate to survive malformed sibling entries")
            return
        }
        #expect(aggregate.start == start)
        #expect(aggregate.end == end)
        #expect(amount == 100)
    }
}


extension StatsDocumentCodingTests {
    private func encode(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(value)
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func monthlyDocument(_ entries: [[String: Any]], kind: String, metric: String) throws -> StatsDocument {
        let json: [String: Any] = ["version": 0, "metric": metric, kind: [source: entries]]
        return try Firestore.Decoder().decode(StatsDocument.self, from: json)
    }
}
