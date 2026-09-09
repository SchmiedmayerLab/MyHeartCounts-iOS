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
import SpeziHealthKit
import Testing


@Suite
struct HealthKitStatsEventTests {
    private struct QuantityMetricMapping {
        let metric: HealthStatsMetric
        let sampleType: SampleType<HKQuantitySample>
        let identifier: String
        let unit: HKUnit
    }

    @Test
    func participationQuantityMetricsUseCanonicalUnits() {
        let mappings: [QuantityMetricMapping] = [
            .init(metric: .activeEnergy, sampleType: .activeEnergyBurned, identifier: "active-energy", unit: .largeCalorie()),
            .init(metric: .walkingRunningDistance, sampleType: .distanceWalkingRunning, identifier: "walking-running-distance", unit: .meter()),
            .init(metric: .flightsClimbed, sampleType: .flightsClimbed, identifier: "flights-climbed", unit: .count()),
            .init(metric: .restingHeartRate, sampleType: .restingHeartRate, identifier: "resting-heart-rate", unit: .count() / .minute())
        ]
        for mapping in mappings {
            #expect(HealthStatsMetric(mapping.sampleType) == mapping.metric)
            #expect(mapping.metric.id.rawValue == mapping.identifier)
            #expect(mapping.metric.sampleType.canonicalUnit == mapping.unit)
        }
    }

    @Test
    func workoutWireFormatPreservesActiveDurationAndIdentity() throws {
        let date = Date(timeIntervalSince1970: 1_788_761_600)
        // This in-memory initializer avoids a HealthKit authorization request or a saved test workout.
        let workout = HKWorkout(
            activityType: .running,
            start: date,
            end: date.addingTimeInterval(2700),
            duration: 2400,
            totalEnergyBurned: nil,
            totalDistance: nil,
            metadata: nil
        )
        let entry = StatsDocument.Workout(workout: workout)
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(StatsDocument.Workout.self, from: data)
        #expect(decoded.date == workout.startDate)
        #expect(decoded.endDate == workout.endDate)
        #expect(decoded.duration == 2400)
        #expect(decoded.activityType == .running)
        #expect(decoded.id == "healthkit:\(workout.uuid.uuidString.lowercased())")
        #expect(decoded.id == StatsDocument.Workout(workout: workout).id)
        let fields = try Firestore.Encoder().encode(entry)
        #expect(Set(fields.keys) == ["id", "date", "endDate", "unit", "value", "duration", "activityType"])
        #expect(fields["unit"] as? String == "s")
        #expect(fields["value"] as? Double == 2400)
        #expect(fields["provenance"] == nil)
        #expect(fields["date"] is String)
        #expect(fields["endDate"] is String)
        #expect(fields["activityType"] as? UInt == HKWorkoutActivityType.running.rawValue)
        let stored = try monthlyDocument([fields], metric: "workouts")
        let snapshot = try StatsStore.Request.workouts(in: .init(date..<workout.endDate.addingTimeInterval(1))).process([stored])
        let workoutSample = try #require(snapshot.elements.first)
        #expect(snapshot.elements.count == 1)
        #expect(snapshot.diagnostics.isEmpty)
        #expect(workoutSample.date == workout.startDate)
        #expect(workoutSample.endDate == workout.endDate)
        #expect(workoutSample.duration == workout.duration)
        #expect(workoutSample.activityType == workout.workoutActivityType)
        #expect(workoutSample.id == entry.id)
    }

    @Test
    func ecgDocumentContainsCountIdentityAndTiming() throws {
        let date = Date(timeIntervalSince1970: 1_788_761_600)
        let entry = StatsDocument.Electrocardiogram(id: "healthkit:ecg-id", date: date, endDate: date.addingTimeInterval(30))
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(StatsDocument.Electrocardiogram.self, from: data)
        #expect(decoded.id == entry.id)
        #expect(decoded.date == date)
        #expect(decoded.endDate == date.addingTimeInterval(30))
        let fields = try Firestore.Encoder().encode(entry)
        #expect(Set(fields.keys) == ["id", "date", "endDate", "unit", "value"])
        #expect(fields["unit"] as? String == "count")
        #expect(fields["value"] as? Int == 1)
        #expect(fields["provenance"] == nil)
        let stored = try monthlyDocument([fields], metric: "electrocardiograms")
        let snapshot = try StatsStore.Request.electrocardiograms(in: .init(date..<entry.endDate.addingTimeInterval(1))).process([stored])
        let recording = try #require(snapshot.elements.first)
        #expect(snapshot.elements.count == 1)
        #expect(snapshot.diagnostics.isEmpty)
        #expect(recording.date == entry.date)
        #expect(recording.endDate == entry.endDate)
        #expect(recording.id == entry.id)
    }

    @Test
    func malformedEventShapesDoNotDiscardValidSiblings() throws {
        let date = Date(timeIntervalSince1970: 0)
        let valid = try Firestore.Encoder().encode(StatsDocument.Workout(
            id: "valid", date: date, endDate: date.addingTimeInterval(3600), duration: 900, activityType: .walking
        ))
        var missingIdentity = valid
        missingIdentity.removeValue(forKey: "id")
        var missingDuration = valid
        missingDuration.removeValue(forKey: "duration")
        var missingActivity = valid
        missingActivity.removeValue(forKey: "activityType")
        var invalidActivity = valid
        invalidActivity["activityType"] = -1
        var inconsistentDuration = valid
        inconsistentDuration["value"] = 800
        var mixedAggregate = valid
        mixedAggregate["start"] = valid["date"]
        mixedAggregate["end"] = valid["endDate"]
        mixedAggregate["unit"] = "s"
        mixedAggregate["sum"] = 900
        let stored = try monthlyDocument([
            valid, missingIdentity, missingDuration, missingActivity, invalidActivity, inconsistentDuration, mixedAggregate
        ], metric: "workouts")
        #expect(stored.malformedEntryCount == 6)
        let snapshot = try StatsStore.Request.workouts(in: .init(date..<date.addingTimeInterval(7200))).process([stored])
        #expect(snapshot.elements.map(\.id) == ["valid"])
        #expect(snapshot.diagnostics == [.malformedEntryCount(6)])
    }

    @Test
    func legacyEventIdentityRemainsReadableButIsNotWrittenAsProvenance() throws {
        let date = Date(timeIntervalSince1970: 0)
        let endDate = date.addingTimeInterval(30)
        let entries: [StatsDocument.Entry] = [
            .workout(.init(id: "healthkit:legacy-workout", date: date, endDate: endDate, duration: 20, activityType: .walking)),
            .electrocardiogram(.init(id: "healthkit:legacy-ecg", date: date, endDate: endDate))
        ]
        for entry in entries {
            var legacy = try Firestore.Encoder().encode(entry)
            let identity = try #require(legacy.removeValue(forKey: "id") as? String)
            legacy["provenance"] = ["observationID": identity, "origins": ["legacy-origin"]]
            let decoded = try Firestore.Decoder().decode(StatsDocument.Entry.self, from: legacy)
            let rewritten = try Firestore.Encoder().encode(decoded)
            #expect(rewritten["id"] as? String == identity)
            #expect(rewritten["provenance"] == nil)
            #expect(rewritten["date"] as? String == legacy["date"] as? String)
            #expect(rewritten["endDate"] as? String == legacy["endDate"] as? String)
        }
    }

    private func monthlyDocument(_ entries: [[String: Any]], metric: String) throws -> StatsDocument {
        try Firestore.Decoder().decode(StatsDocument.self, from: [
            "version": 0, "metric": metric, "samples": ["com.apple.HealthKit": entries]
        ])
    }
}
