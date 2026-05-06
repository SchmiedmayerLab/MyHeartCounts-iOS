//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

// swiftlint:disable file_types_order

import Foundation
import HealthKit
import MyHeartCountsShared
import SpeziHealthKit
import SpeziHealthKitUI
import SpeziLocalization
import SpeziViews
import struct SwiftUI.Color


enum MHCSampleType: Hashable, Identifiable, Sendable {
    case healthKit(SampleTypeProxy)
    case custom(CustomQuantitySampleType)
    
    var id: AnyHashable {
        switch self {
        case .healthKit(let sampleType):
            sampleType.id
        case .custom(let sampleType):
            sampleType.id
        }
    }
    
    var displayTitle: String {
        switch self {
        case .healthKit(let sampleType):
            sampleType.underlyingSampleType.mhcDisplayTitle
        case .custom(let sampleType):
            String(localized: sampleType.displayTitle)
        }
    }
    
    var displayUnit: HKUnit? {
        if let unit = asQuantityType?.displayUnit {
            unit
        } else {
            switch self {
            case .healthKit(.correlation(.bloodPressure)):
                SampleType.bloodPressure.associatedQuantityTypes.first?.displayUnit
            default:
                nil
            }
        }
    }
    
    var asQuantityType: MHCQuantitySampleType? {
        .init(self)
    }
    
    func displayTitle(in locale: Locale) -> String {
        switch self {
        case .healthKit(let sampleType):
            sampleType.underlyingSampleType.localizedTitle(in: locale.language) ?? sampleType.underlyingSampleType.mhcDisplayTitle
        case .custom(let sampleType):
            sampleType.displayTitle.localizedString(for: locale)
        }
    }
}


extension MHCSampleType {
    private static let sampleTypeProxyByIdentifier: [String: SampleTypeProxy] = HKObjectType.allKnownObjectTypes.reduce(into: [:]) { result, type in
        if let sampleType = type.sampleType, let proxy = SampleTypeProxy(_ifPossible: sampleType) {
            result[type.identifier] = proxy
        }
    }
    
    /// Attempts to create an `MHCSampleType` from a raw identifier string.
    init?(sampleTypeIdentifier identifier: String) {
        if let custom = CustomQuantitySampleType(identifier: identifier) {
            self = .custom(custom)
        } else if let proxy = Self.sampleTypeProxyByIdentifier[identifier] {
            self = .healthKit(proxy)
        } else {
            return nil
        }
    }
}


struct CustomQuantitySampleType: Hashable, Identifiable, Sendable {
    let id: String
    let displayTitle: LocalizedStringResource
    let displayUnit: HKUnit
    let aggregationKind: StatisticsAggregationOption
    let preferredTintColor: Color
    
    init(
        id: String,
        displayTitle: LocalizedStringResource,
        displayUnit: HKUnit,
        aggregationKind: StatisticsAggregationOption,
        preferredTintColor: Color
    ) {
        self.id = id
        self.displayTitle = displayTitle
        self.displayUnit = displayUnit
        self.aggregationKind = aggregationKind
        self.preferredTintColor = preferredTintColor
    }
}


extension CustomQuantitySampleType {
    static let bloodLipids = Self(
        id: "MHCCustomSampleTypeBloodLipidMeasurement",
        displayTitle: "Blood Lipids",
        displayUnit: .gramUnit(with: .milli) / .literUnit(with: .deci),
        aggregationKind: .avg,
        preferredTintColor: .yellow // ???
    )
    
    static let dietMEPAScore = Self(
        id: "MHCCustomSampleTypeDietMEPAScore",
        displayTitle: "Diet",
        displayUnit: .count(),
        aggregationKind: .avg,
        preferredTintColor: .blue // ???
    )
    
    static let mentalWellbeingScore = Self(
        id: "MHCCustomSampleTypeWHO5Score",
        displayTitle: "Mental Well Being",
        displayUnit: .count(), // percentage???
        aggregationKind: .avg,
        preferredTintColor: .blue // ???
    )
    
    static let nicotineExposure = Self(
        id: "MHCCustomSampleTypeNicotineExposure",
        displayTitle: "Nicotine Exposure",
        displayUnit: .count(),
        aggregationKind: .avg,
        preferredTintColor: .brown // ???
    )
    
    init?(identifier: String) {
        let wellKnownSampleTypes: [Self] = [.bloodLipids, .dietMEPAScore, .nicotineExposure, .mentalWellbeingScore]
        if let sampleType = wellKnownSampleTypes.first(where: { $0.id == identifier }) {
            self = sampleType
        } else {
            return nil
        }
    }
}


enum MHCQuantitySampleType: Hashable, Identifiable, Sendable {
    case healthKit(SampleType<HKQuantitySample>)
    case custom(CustomQuantitySampleType)
    
    var id: String {
        switch self {
        case .healthKit(let sampleType):
            sampleType.id
        case .custom(let sampleType):
            sampleType.id
        }
    }
    
    var displayTitle: String {
        switch self {
        case .healthKit(let sampleType):
            sampleType.mhcDisplayTitle
        case .custom(let sampleType):
            String(localized: sampleType.displayTitle)
        }
    }
    
    var displayUnit: HKUnit {
        switch self {
        case .healthKit(let sampleType):
            sampleType.displayUnit
        case .custom(let sampleType):
            sampleType.displayUnit
        }
    }
    
    init?(_ other: MHCSampleType) {
        switch other {
        case .healthKit(.quantity(let sampleType)):
            self = .healthKit(sampleType)
        case .custom(let sampleType):
            self = .custom(sampleType)
        case .healthKit:
            return nil
        }
    }
}


struct QuantitySample: Hashable, Identifiable, Sendable {
    typealias SampleType = MHCQuantitySampleType
    
    let id: UUID
    let sampleType: SampleType
    let unit: HKUnit
    let value: Double
    let startDate: Date
    let endDate: Date
    
    var timeRange: Range<Date> {
        startDate..<endDate
    }
    
    init(id: UUID, sampleType: SampleType, unit: HKUnit, value: Double, startDate: Date, endDate: Date) {
        self.id = id
        self.sampleType = sampleType
        self.unit = unit
        self.value = value
        self.startDate = startDate
        self.endDate = endDate
        checkDateRangeValid()
    }
    
    init(id: UUID, sampleType: SampleType, unit: HKUnit, value: Double, date: Date) {
        self.init(id: id, sampleType: sampleType, unit: unit, value: value, startDate: date, endDate: date)
    }
    
    init(id: UUID, sampleType: SampleType, quantity: HKQuantity, startDate: Date, endDate: Date) {
        self.init(
            id: id,
            sampleType: sampleType,
            unit: sampleType.displayUnit,
            value: quantity.doubleValue(for: sampleType.displayUnit),
            startDate: startDate,
            endDate: endDate
        )
    }
    
    init(_ other: HKQuantitySample) {
        guard let sampleType = SpeziHealthKit.SampleType<HKQuantitySample>(HKQuantityTypeIdentifier(rawValue: other.quantityType.identifier)) else {
            preconditionFailure("Unable to obtain SampleType<HKQuantitySample> for HKQuantityType '\(other.quantityType.identifier)'")
        }
        self.init(
            id: other.uuid,
            sampleType: .healthKit(sampleType),
            quantity: other.quantity,
            startDate: other.startDate,
            endDate: other.endDate
        )
    }
    
    private func checkDateRangeValid() {
        precondition(endDate >= startDate)
    }
    
    // periphery:ignore - API
    func value(as unit: HKUnit) -> Double {
        self.unit == unit ? value : HKQuantity(unit: self.unit, doubleValue: value).doubleValue(for: unit)
    }
    
    func valueAndUnitDescription(for unit: HKUnit? = nil) -> String {
        let unit = unit ?? self.unit
        let quantity = HKQuantity(unit: self.unit, doubleValue: self.value)
        if unit == HKUnit.foot() && sampleType == .healthKit(.height) {
            let (feet, inches) = quantity.valuesForFeetAndInches()
            return "\(feet)‘ \(Int(inches))“"
        } else {
            return "\(quantity.doubleValue(for: unit).formatted(.number.precision(.fractionLength(0...2)))) \(unit.unitString)"
        }
    }
}


extension Collection where Element == QuantitySample {
    func aggregated(
        using kind: StatisticsAggregationOption,
        over timeInterval: HealthKitStatisticsQuery.AggregationInterval,
        anchor: Date,
        overallTimeRange: Range<Date>,
        calendar: Calendar
    ) -> [QuantitySample] {
        calendar
            .dates(
                byAdding: timeInterval.intervalComponents,
                startingAt: anchor,
                in: anchor..<overallTimeRange.upperBound
            )
            // `Calendar.dates(byAdding:startingAt:in:)` doesn't include the start date, so we need to manually prepend it to the sequence.
            .chaining(after: CollectionOfOne(anchor))
            .lazy
            .compactMap { date -> Range<Date>? in
                calendar.date(byAdding: timeInterval.intervalComponents, to: date).map { date..<$0 }
            }
            .flatMap { (range: Range<Date>) in
                self.lazy.filter { sample in
                    if sample.startDate == sample.endDate {
                        // if the sample represents a single point in time, we simply check whether the range contains that instant
                        range.contains(sample.startDate)
                    } else {
                        // otherwise (if the sample represents a time period), we check for overlap
                        range.overlaps(sample.timeRange)
                    }
                }
                .map { sample in
                    switch kind {
                    case .avg, .min, .max:
                        // for the non-cumulative options, we can simply pass the data on unchanged.
                        return sample
                    case .sum:
                        if sample.startDate == sample.endDate || (range.contains(sample.startDate) && range.contains(sample.endDate)) {
                            // if the sample is fully contained w/in the range, we pass it on unchanged
                            return sample
                        } else {
                            // otherwise, we determine how much of the sample falls into this time range, and return that
                            let overlapAmount = sample.endDate.timeIntervalSince(sample.startDate) / range.timeInterval
                            return QuantitySample(
                                id: sample.id,
                                sampleType: sample.sampleType,
                                unit: sample.unit,
                                value: sample.value * overlapAmount,
                                startDate: Swift.max(sample.startDate, range.lowerBound),
                                endDate: Swift.min(sample.endDate, range.upperBound)
                            )
                        }
                    }
                }
            }
    }
    
    
    func aggregated( // swiftlint:disable:this cyclomatic_complexity
        using input: HealthDashboardLayout.SingleValueConfig._Variant,
        overallTimeRange: Range<Date>,
        calendar: Calendar
    ) -> [QuantitySample] {
        guard let firstSample = first else {
            return []
        }
        let sampleType = firstSample.sampleType
        switch input {
        case .mostRecentSample:
            if let sample = self.max(by: \.endDate) {
                return [sample]
            } else {
                return []
            }
        case let .aggregated(steps, final):
            var samples = Array(self)
            for step in steps {
                samples = samples.aggregated(
                    using: step.kind,
                    over: step.interval,
                    anchor: calendar.startOfDay(for: overallTimeRange.lowerBound),
                    overallTimeRange: overallTimeRange,
                    calendar: calendar
                )
            }
            guard !samples.isEmpty else {
                return samples // de-facto unreachable, but we wanna be safe
            }
            guard let final else {
                return samples
            }
            return [
                QuantitySample(
                    id: UUID(), // ???
                    sampleType: sampleType,
                    unit: sampleType.displayUnit,
                    value: { () -> Double in
                        switch final {
                        case .sum:
                            samples.reduce(0) { $0 + $1.value }
                        case .avg:
                            samples.reduce(0) { $0 + $1.value } / Double(samples.count)
                        case .min:
                            // SAFETY: we know that samples is non-empty
                            samples.min(of: \.value)! // swiftlint:disable:this force_unwrapping
                        case .max:
                            // SAFETY: we know that samples is non-empty
                            samples.max(of: \.value)! // swiftlint:disable:this force_unwrapping
                        }
                    }(),
                    // SAFETY: we know that samples is non-empty
                    startDate: samples.min(of: \.startDate)!, // swiftlint:disable:this force_unwrapping
                    // SAFETY: we know that samples is non-empty
                    endDate: samples.max(of: \.endDate)! // swiftlint:disable:this force_unwrapping
                )
            ]
        }
    }
}


extension Range where Bound == Date {
    var timeInterval: TimeInterval {
        upperBound.timeIntervalSince(lowerBound)
    }
}
