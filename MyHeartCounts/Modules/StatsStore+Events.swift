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
import SpeziHealthKit
import SpeziHealthKitUI


extension StatsStore.Request where Element == WorkoutStatsSample {
    private struct WorkoutProcessor: MyHeartCountsShared.ValueTransformer {
        let timeRange: Range<Date>
        let sourcePolicy: StatsStore.SourcePolicy

        func transform(_ documents: [StatsDocument]) throws -> StatsStore.Processor.Output<WorkoutStatsSample> {
            try StatsStore.Processor.workouts(documents: documents, timeRange: timeRange, sourcePolicy: sourcePolicy)
        }
    }

    /// Select workouts contained in the requested range using the shared source-selection policy.
    static func workouts(in timeRange: HealthKitQueryTimeRange, sourcePolicy: StatsStore.SourcePolicy = .automatic) -> Self {
        let range = timeRange.range
        return Self(metricId: .workouts, timeRange: range, processor: WorkoutProcessor(timeRange: range, sourcePolicy: sourcePolicy))
    }
}


extension StatsStore.Request where Element == ElectrocardiogramStatsSample {
    private struct ElectrocardiogramProcessor: MyHeartCountsShared.ValueTransformer {
        let timeRange: Range<Date>
        let sourcePolicy: StatsStore.SourcePolicy

        func transform(_ documents: [StatsDocument]) throws -> StatsStore.Processor.Output<ElectrocardiogramStatsSample> {
            try StatsStore.Processor.electrocardiograms(documents: documents, timeRange: timeRange, sourcePolicy: sourcePolicy)
        }
    }

    /// Select recordings contained in the requested range, preserving their completion timestamps for milestones.
    static func electrocardiograms(in timeRange: HealthKitQueryTimeRange, sourcePolicy: StatsStore.SourcePolicy = .automatic) -> Self {
        let range = timeRange.range
        return Self(
            metricId: .electrocardiograms,
            timeRange: range,
            processor: ElectrocardiogramProcessor(timeRange: range, sourcePolicy: sourcePolicy)
        )
    }
}


extension StatsStore.Processor {
    static func workouts(
        documents: [StatsDocument], timeRange: Range<Date>, sourcePolicy: StatsStore.SourcePolicy = .automatic
    ) throws -> Output<WorkoutStatsSample> {
        let input = Input(metricID: "workouts", timeRange: timeRange, sourcePolicy: sourcePolicy, unit: .second(), aggregationKind: .sum)
        var diagnostics: [StatsStore.Diagnostic] = []
        let values = try selectedValues(documents: documents, input: input, diagnostics: &diagnostics)
        return Output(
            elements: values.compactMap { value in
                guard case .workout(let workout) = value.event else {
                    return nil
                }
                return WorkoutStatsSample(
                    id: workout.id, date: workout.date, endDate: workout.endDate, duration: workout.duration, activityType: workout.activityType
                )
            },
            diagnostics: diagnostics,
            contributingSourceIDs: Set(values.flatMap(\.sources))
        )
    }

    static func electrocardiograms(
        documents: [StatsDocument], timeRange: Range<Date>, sourcePolicy: StatsStore.SourcePolicy = .automatic
    ) throws -> Output<ElectrocardiogramStatsSample> {
        let input = Input(
            metricID: "electrocardiograms", timeRange: timeRange, sourcePolicy: sourcePolicy, unit: .count(), aggregationKind: .sum
        )
        var diagnostics: [StatsStore.Diagnostic] = []
        let values = try selectedValues(documents: documents, input: input, diagnostics: &diagnostics)
        return Output(
            elements: values.compactMap { value in
                guard case .electrocardiogram(let electrocardiogram) = value.event else {
                    return nil
                }
                return ElectrocardiogramStatsSample(
                    id: electrocardiogram.id, date: electrocardiogram.date, endDate: electrocardiogram.endDate
                )
            },
            diagnostics: diagnostics,
            contributingSourceIDs: Set(values.flatMap(\.sources))
        )
    }
}
