//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

// swiftlint:disable file_types_order

import Foundation
import GroveHealthKit
import GroveHealthKitUI
import GroveLocalization
import GroveViews
import HealthKit
import MyHeartCountsShared
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
    let canonicalUnit: HKUnit
    let displayTitle: LocalizedStringResource
    let displayUnit: HKUnit
    let aggregationKind: StatisticsAggregationOption
    let preferredTintColor: Color
    
    init(
        id: String,
        canonicalUnit: HKUnit,
        displayTitle: LocalizedStringResource,
        displayUnit: HKUnit? = nil,
        aggregationKind: StatisticsAggregationOption,
        preferredTintColor: Color
    ) {
        self.id = id
        self.canonicalUnit = canonicalUnit
        self.displayTitle = displayTitle
        self.displayUnit = displayUnit ?? canonicalUnit
        self.aggregationKind = aggregationKind
        self.preferredTintColor = preferredTintColor
    }
}


extension CustomQuantitySampleType {
    static let bloodLipids = Self(
        id: "MHCCustomSampleTypeBloodLipidMeasurement",
        canonicalUnit: .gramUnit(with: .milli) / .literUnit(with: .deci),
        displayTitle: "Blood Lipids",
        aggregationKind: .avg,
        preferredTintColor: .red
    )
    
    static let dietMEPAScore = Self(
        id: "MHCCustomSampleTypeDietMEPAScore",
        canonicalUnit: .count(),
        displayTitle: "Diet",
        aggregationKind: .avg,
        preferredTintColor: .green
    )
    
    static let mentalWellbeingScore = Self(
        id: "MHCCustomSampleTypeWHO5Score",
        canonicalUnit: .count(), // percentage???
        displayTitle: "Mental Well Being",
        aggregationKind: .avg,
        preferredTintColor: .blue
    )
    
    static let nicotineExposure = Self(
        id: "MHCCustomSampleTypeNicotineExposure",
        canonicalUnit: .count(),
        displayTitle: "Nicotine Exposure",
        aggregationKind: .avg,
        preferredTintColor: .gray
    )
    
    /// Glycated hemoglobin (HbA1c): the share of hemoglobin with glucose attached, reflecting the average blood glucose over the past 2–3 months.
    ///
    /// HealthKit has no HbA1c type, so these samples never enter HealthKit. Their canonical value is in NGSP percentage points
    /// (e.g. `6.5` for 6.5 %; not HealthKit's 0...1 fraction convention for `HKUnit.percent()`).
    /// Participants in the UK see and enter IFCC mmol/mol instead; see ``HbA1cScale`` for why that conversion can't go through `HKUnit`.
    ///
    /// - Note: The identifier predates the type's first use, and is what the backend writes HeartRisk HbA1c answers under.
    static let hbA1c = Self(
        id: "MHCCustomSampleTypeBloodGlucoseA1c",
        canonicalUnit: .percent(),
        displayTitle: "HbA1c",
        // UK health services report HbA1c in mmol/mol; elsewhere (incl. the US), it's reported in percent.
        displayUnit: Locale.current.measurementSystem == .uk ? .hbA1cMillimolesPerMole : .percent(),
        aggregationKind: .avg,
        preferredTintColor: .red
    )

    init?(identifier: String) {
        let wellKnownSampleTypes: [Self] = [.bloodLipids, .dietMEPAScore, .nicotineExposure, .mentalWellbeingScore, .hbA1c]
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
    
    var canonicalUnit: HKUnit {
        switch self {
        case .healthKit(let sampleType):
            sampleType.canonicalUnit
        case .custom(let sampleType):
            sampleType.canonicalUnit
        }
    }
    
    var displayUnit: HKUnit {
        switch self {
        case .healthKit(.bodyMass) where Locale.current.measurementSystem == .uk:
            // Grove displays body mass in pounds for the UK measurement system, but UK health services record it in kilograms.
            .gramUnit(with: .kilo)
        case .healthKit(.bloodGlucose) where Locale.current.measurementSystem == .uk:
            // Grove displays blood glucose in mg/dL everywhere, but UK health services record it in mmol/L.
            .bloodGlucoseMillimolesPerLiter
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
    /// The quantity's value, in `sampleType.canonicalUnit`
    private let value: Double
    let startDate: Date
    let endDate: Date
    
    var timeRange: Range<Date> {
        startDate..<endDate
    }
    
    init(id: UUID, sampleType: SampleType, unit: HKUnit, value: Double, startDate: Date, endDate: Date) {
        let canonicalValue = sampleType.convert(value, from: unit, to: sampleType.canonicalUnit)
        self.init(
            id: id,
            sampleType: sampleType,
            quantity: HKQuantity(unit: sampleType.canonicalUnit, doubleValue: canonicalValue),
            startDate: startDate,
            endDate: endDate
        )
    }
    
    init(id: UUID, sampleType: SampleType, unit: HKUnit, value: Double, date: Date) {
        self.init(id: id, sampleType: sampleType, unit: unit, value: value, startDate: date, endDate: date)
    }
    
    init(id: UUID, sampleType: SampleType, quantity: HKQuantity, startDate: Date, endDate: Date) {
        self.id = id
        self.sampleType = sampleType
        self.value = quantity.doubleValue(for: sampleType.canonicalUnit)
        self.startDate = startDate
        self.endDate = endDate
        checkDateRangeValid()
    }
    
    init(_ other: HKQuantitySample) {
        guard let sampleType = GroveHealthKit.SampleType<HKQuantitySample>(HKQuantityTypeIdentifier(rawValue: other.quantityType.identifier)) else {
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
    
    func value(as unit: HKUnit) -> Double {
        sampleType.convert(value, from: sampleType.canonicalUnit, to: unit)
    }

    /// The sample's quantity, in its canonical unit.
    ///
    /// - Important: Convert the sample's value via ``value(as:)``, never by converting this quantity:
    ///     `HKQuantity` gets the conversions of some sample types (e.g. ``CustomQuantitySampleType/hbA1c``) wrong.
    func hkQuantity() -> HKQuantity {
        HKQuantity(unit: sampleType.canonicalUnit, doubleValue: value)
    }

    func valueAndUnitDescription(for unit: HKUnit? = nil) -> String {
        let unit = unit ?? sampleType.canonicalUnit
        if unit == HKUnit.foot() && sampleType == .healthKit(.height) {
            let (feet, inches) = hkQuantity().valuesForFeetAndInches()
            return "\(feet)‘ \(Int(inches))“"
        } else {
            return "\(value(as: unit).formatted(.number.precision(.fractionLength(0...2)))) \(unit.mhcDisplayString)"
        }
    }
}


extension MHCQuantitySampleType {
    /// Converts a value of this sample type from one unit into another.
    ///
    /// Use this instead of `HKQuantity` conversions, which get HbA1c wrong (see ``HbA1cScale``).
    func convert(_ value: Double, from sourceUnit: HKUnit, to targetUnit: HKUnit) -> Double {
        guard sourceUnit != targetUnit else {
            return value
        }
        if self == .custom(.hbA1c) {
            // HbA1c's two scales are related by an offset; we go through percent, the type's canonical unit.
            let percent = sourceUnit == .hbA1cMillimolesPerMole
                ? HbA1cScale.percent(fromMillimolesPerMole: value)
                : HKQuantity(unit: sourceUnit, doubleValue: value).doubleValue(for: .percent())
            return targetUnit == .hbA1cMillimolesPerMole
                ? HbA1cScale.millimolesPerMole(fromPercent: percent)
                : HKQuantity(unit: .percent(), doubleValue: percent).doubleValue(for: targetUnit)
        }
        return HKQuantity(unit: sourceUnit, doubleValue: value).doubleValue(for: targetUnit)
    }
}


/// Converts between HbA1c's two unit scales: NGSP percentage points (used e.g. in the US) and IFCC mmol/mol (used e.g. in the UK).
///
/// The two scales are related by an offset, which `HKUnit` can't express:
/// it treats both as plain ratios of a dimensionless count, and would turn 6.5 % into 65 mmol/mol, instead of the correct 48.
enum HbA1cScale {
    /// `mmol/mol = 10.929 × (% − 2.15)`, the IFCC–NGSP master equation.
    static func millimolesPerMole(fromPercent percent: Double) -> Double {
        10.929 * (percent - 2.15)
    }

    /// The inverse of ``millimolesPerMole(fromPercent:)``.
    static func percent(fromMillimolesPerMole value: Double) -> Double {
        value / 10.929 + 2.15
    }
}


extension HKUnit {
    /// mg/dL, the unit of ``CVHScore``'s blood lipids and blood glucose scoring bands.
    static let milligramsPerDeciliter = HKUnit.gramUnit(with: .milli).unitDivided(by: .literUnit(with: .deci))

    /// Blood glucose in mmol/L.
    ///
    /// - Important: Plain `HKUnit(from: "mmol/L")` lacks glucose's molar mass, and can't be converted into mg/dL.
    static let bloodGlucoseMillimolesPerLiter = HKUnit.moleUnit(with: .milli, molarMass: HKUnitMolarMassBloodGlucose).unitDivided(by: .liter())

    /// HbA1c in IFCC units: mmol of HbA1c per mol of total hemoglobin. Convert values via ``HbA1cScale``.
    static let hbA1cMillimolesPerMole = HKUnit(from: "mmol/mol")

    /// The unit, as we show it to the participant.
    ///
    /// Differs from `unitString` for units that encode a molar mass (`unitString` spells blood glucose's mmol/L as `mmol<180.15588…>/L`).
    var mhcDisplayString: String {
        self == .bloodGlucoseMillimolesPerLiter ? "mmol/L" : unitString
    }
}


extension Range where Bound == Date {
    var timeInterval: TimeInterval {
        upperBound.timeIntervalSince(lowerBound)
    }
}
