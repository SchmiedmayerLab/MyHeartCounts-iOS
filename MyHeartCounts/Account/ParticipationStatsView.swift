//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

// swiftlint:disable all

import Algorithms
import HealthKit
import MyHeartCountsShared
import SpeziFoundation
import SpeziHealthKit
import SpeziHealthKitUI
import SpeziStudy
import SwiftUI


struct ParticipationStatsView: View {
    @Environment(\.calendar) private var cal
    @Environment(HealthKit.self) private var healthKit
    
    private let enrollment: StudyEnrollment
//    @StudyManagerQuery private var enrollments: [StudyEnrollment]
    
//    @HealthKitStatisticsQuery private var stepCountStats: [HKStatistics]
//    @HealthKitQuery<HKQuantitySample> private var heartRateMeasurements: Slice<OrderedArray<HKQuantitySample>>
    @HealthKitStatisticsQuery private var heartRateAverages: [HKStatistics]
    
    @State private var totalNumSteps = 0
    @State private var totalNumHeartBeats: Double = 0
    @State private var totalNumHeartBeats2: Double = 0
    
    init(enrollment: StudyEnrollment) {
        self.enrollment = enrollment
//        self._stepCountStats = .init(.stepCount, aggregatedBy: .sum, over: .year, timeRange: .startingAt(enrollment.enrollmentDate))
//        self._heartRateAverages = .init(.heartRate, aggregatedBy: .avg, over: .day, timeRange: .startingAt(Calendar.current.startOfDay(for: enrollment.enrollmentDate)))
        self._heartRateAverages = .init(.heartRate, aggregatedBy: .avg, over: .hour, timeRange: .startingAt(enrollment.enrollmentDate))
    }
    
    var body: some View {
        // TOOD make it look cool!
//        Form {
//            Section {
//                LabeledContent("Enrolled Since" as String, value: enrollment.enrollmentDate, format: .dateTime)
//                if let numDaysEnrolled = cal.dateComponents([.day], from: cal.startOfDay(for: enrollment.enrollmentDate), to: cal.startOfDay(for: .now)).day {
//                    LabeledContent("Days Enrolled" as String, value: numDaysEnrolled, format: .number)
//                }
//            }
//            Section {
//                LabeledContent("#steps" as String, value: totalNumSteps, format: .number)
//                LabeledContent("#heartBeats" as String, value: totalNumHeartBeats, format: .number)
//            }
//        }
        ScrollView {
            content
        }
        .navigationTitle("Participation Stats")
//        .task(id: stepCountStats) {
//            totalNumSteps = stepCountStats.reduce(0) { $0 + Int($1.sumQuantity()?.doubleValue(for: .count()) ?? 0) }
//        }
//        .task(id: heartRateMeasurements) {
        .task {
            totalNumSteps = try! await healthKit
                .statisticsQuery(.stepCount, aggregatedBy: [.sum], over: .year, timeRange: .startingAt(enrollment.enrollmentDate))
                .reduce(0) { $0 + Int($1.sumQuantity()?.doubleValue(for: .count()) ?? 0) }
            let allHeartbeats = try! await healthKit
                .query(.heartRate, timeRange: .startingAt(enrollment.enrollmentDate))
//                .reduce(into: 0) { result, sample in
//                    precondition(sample.count == 1)
//                    precondition(sample.startDate == sample.endDate, "sample")
//                }
            for window in allHeartbeats.windows(ofCount: 3) {
                let left = window[window.startIndex]
                let sample = window[window.startIndex + 1]
                let right = window[window.startIndex + 2]
                let bpm = sample.quantity.doubleValue(for: .count() / .minute())
                let timeIntervalIMin = (((left.endDate..<sample.startDate).middle)..<((sample.endDate..<right.startDate).middle)).timeInterval / 60
                totalNumHeartBeats += bpm * timeIntervalIMin
            }
//            print("#samples", heartRateMeasurements.count)
//            print(heartRateMeasurements.count { $0.startDate != $0.endDate })
            // TODO parallelise this?
//            totalNumHeartBeats = heartRateMeasurements.reduce(into: 0) { total, sample in
//                precondition(sample.count == 1)
////                precondition(sample.startDate != sample.endDate)
//                let bpm = sample.quantity.doubleValue(for: .count() / .minute())
//                let durationInMin = sample.timeRange.timeInterval / 60
//                total += bpm
//            }
        }
        .task(id: heartRateAverages) {
            var total: Double = 0
//            print()
            for stats in heartRateAverages {
                guard let bpm = stats.averageQuantity()?.doubleValue(for: .count() / .minute()) else {
                    // will always be nonnil
                    continue
                }
//                print(stats.timeRange, stats.averageQuantity()?.doubleValue(for: .count() / .minute()))
                let timeRange = stats.timeRange.clamped(to: enrollment.enrollmentDate..<Date.now)
                let numMinutes = timeRange.timeInterval / 60
                total += bpm * numMinutes
            }
            totalNumHeartBeats2 = total
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Increment Stats") {
                    withAnimation {
                        totalNumSteps += .random(in: -50...50)
                        totalNumHeartBeats += .random(in: -50...50)
                        totalNumHeartBeats2 += .random(in: -50...50)
                    }
                }
            }
        }
    }
    
    @ViewBuilder private var content: some View {
        VStack(spacing: 50) {
            enrollmentDurationSection
            healthStatsSections
        }
    }
    
    
    @ViewBuilder private var enrollmentDurationSection: some View {
        if let numDaysEnrolled = cal.dateComponents([.day], from: cal.startOfDay(for: enrollment.enrollmentDate), to: cal.startOfDay(for: .now)).day {
            StatCell(title: "Enrolled for", subtitle: "Since \(enrollment.enrollmentDate, format: .dateTime.omittingTime())") {
                StatCellContentNumberWithUnit(numDaysEnrolled, format: .number, unit: "days")
            }
        }
    }
    
    @ViewBuilder private var healthStatsSections: some View {
        StatCell(
            title: "Steps Taken",
            subtitle: "Total Number of Steps While Enrolled"
        ) {
            StatCellContentNumberWithUnit(totalNumSteps, format: .number)
        }
        Divider()
        StatCell(
            title: "Heartbeats",
            subtitle: "Total Number of Heartbeats While Enrolled (Est.)"
        ) {
            StatCellContentNumberWithUnit(totalNumHeartBeats, format: .number.rounded(rule: .down, increment: 1))
        }
        StatCell(
            title: "Heartbeats",
            subtitle: "Total Number of Heartbeats While Enrolled (Est.)"
        ) {
            StatCellContentNumberWithUnit(totalNumHeartBeats2, format: .number.rounded(rule: .down, increment: 1))
        }
    }
}

private struct StatCell<Content: View>: View {
    private let title: LocalizedStringResource
    private let subtitle: LocalizedStringResource
    private let content: Content
    
    var body: some View {
        VStack {
            Text(title)
            content
            Text(subtitle)
        }
    }
    
    init(title: LocalizedStringResource, subtitle: LocalizedStringResource, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }
}


private struct StatCellContentNumberWithUnit<Value: Equatable, Format: FormatStyle<Value, String>>: View {
    private let value: Value
    private let format: Format
    private let unit: String
    private let doubleValue: Double
    
    var body: some View {
        Text(value, format: format)
            .font(.system(size: 32, weight: .bold))
            .overlay(alignment: .trailingLastTextBaseline) {
                Text(unit)
                    .alignmentGuide(.trailing) { $0[.leading] }
                    .padding(.leading, 4)
            }
            .contentTransition(.numericText(value: doubleValue))
            .monospacedDigit()
    }
    
    init(_ value: Value, format: Format, unit: String = "") where Value: BinaryInteger {
        self.value = value
        self.format = format
        self.unit = unit
        self.doubleValue = Double(value)
    }
    
    init(_ value: Value, format: Format, unit: String = "") where Value: BinaryFloatingPoint {
        self.value = value
        self.format = format
        self.unit = unit
        self.doubleValue = Double(value)
    }
}
