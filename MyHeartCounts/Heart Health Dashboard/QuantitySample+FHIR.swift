//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import HealthKit
import SpeziHealthKitFHIR
import ModelsR4
import MyHeartCountsShared
import SpeziFoundation
import SpeziHealthKit
import FHIRModelsExtensions


extension QuantitySample: HealthObservation {
    enum FHIRObservationConversionError: Error {
        case notSupported
    }
    
    // SAFETY: this is in fact safe, since the FHIRPrimitive's `extension` property is empty.
    // As a result, the actual instance doesn't contain any mutable state, and since this is a let,
    // it also never can be mutated to contain any.
    nonisolated(unsafe) private static let speziSystem = "https://spezi.stanford.edu".asFHIRURIPrimitive()! // swiftlint:disable:this force_unwrapping
    
    var sampleTypeIdentifier: String {
        self.sampleType.id
    }
    
    // swiftlint:disable:next function_body_length
    func resource(
        withMapping mapping: HKSampleMapping,
        issuedDate: FHIRPrimitive<Instant>?,
        extensions: [any FHIRExtensionBuilderProtocol]
    ) throws -> ResourceProxy {
        let observation = Observation(
            code: CodeableConcept(),
            status: FHIRPrimitive(.final)
        )
        // Set basic elements applicable to all observations
        observation.id = self.id.uuidString.asFHIRStringPrimitive()
        observation.appendIdentifier(Identifier(id: observation.id))
        try observation.setEffective(startDate: self.startDate, endDate: self.endDate, timeZone: .current)
        if let issuedDate {
            observation.issued = issuedDate
        } else {
            try observation.setIssued(on: .now)
        }
        switch sampleType {
        case .healthKit(let sampleType):
            let sample = HKQuantitySample(
                type: sampleType.hkSampleType,
                quantity: HKQuantity(unit: self.unit, doubleValue: self.value),
                start: self.startDate,
                end: self.endDate
            )
            return try sample.resource(withMapping: mapping, issuedDate: issuedDate)
        case .custom(.bloodLipids):
            let code = "18262-6".asFHIRStringPrimitive() // "Cholesterol in LDL [Mass/volume] in Serum or Plasma by Direct assay"
            let system = "http://loinc.org".asFHIRURIPrimitive()
            observation.appendCodings([
                Coding(code: code, system: system),
                Coding(
                    code: sampleType.id.asFHIRStringPrimitive(),
                    display: sampleType.displayTitle.asFHIRStringPrimitive(),
                    system: Self.speziSystem
                )
            ])
            observation.value = .quantity(Quantity(
                code: code,
                system: system,
                unit: "mg/dL".asFHIRStringPrimitive(),
                value: value.asFHIRDecimalPrimitive()
            ))
        case .custom(.nicotineExposure), .custom(.dietMEPAScore), .custom(.mentalWellbeingScore):
            let code = sampleType.id.asFHIRStringPrimitive()
            observation.appendCoding(Coding(
                code: code,
                display: sampleType.displayTitle.asFHIRStringPrimitive(),
                system: Self.speziSystem
            ))
            observation.value = .quantity(Quantity(
                code: code,
                system: Self.speziSystem,
                unit: "count",
                value: value.asFHIRDecimalPrimitive()
            ))
        default:
            throw FHIRObservationConversionError.notSupported
        }
        for builder in extensions {
            try builder.apply(typeErasedInput: self, to: observation)
        }
        observation.addMHCAppAsSource()
        return .observation(observation)
    }
}


extension QuantitySample {
    /// Attempts to create a ``QuantitySample`` from a FHIR `ResourceProxy`.
    ///
    /// - parameter sampleTypeHint: the expected sample type. if you specify `nil`, the function will attempt to determine the sample type automatically, based on the Observation.
    init?(_ resourceProxy: ModelsR4.ResourceProxy, sampleTypeHint: MHCQuantitySampleType? = nil) {
        switch resourceProxy {
        case .observation(let observation):
            if let sample = Self(observation, sampleTypeHint: sampleTypeHint) {
                self = sample
            } else {
                return nil
            }
        default:
            return nil
        }
    }
    
    /// Attempts to create a ``QuantitySample`` from a FHIR `Observation`.
    ///
    /// - parameter sampleTypeHint: the expected sample type. if you specify `nil`, the function will attempt to determine the sample type automatically, based on the Observation.
    init?(_ observation: ModelsR4.Observation, sampleTypeHint: MHCQuantitySampleType? = nil) {
        // swiftlint:disable:previous function_body_length cyclomatic_complexity
        guard let id = (observation.id?.value?.string).flatMap({ UUID(uuidString: $0) }),
              case .quantity(let quantity) = observation.value,
              let rawUnit = quantity.unit?.value?.string,
              let unit = try? catchingNSException({ HKUnit(from: rawUnit) }),
              let value = (quantity.value?.value?.decimal).map({ Double($0) }),
              let effective = observation.effective,
              let coding = observation.code.coding else {
            return nil
        }
        let startDate: Date
        let endDate: Date
        switch effective {
        case .dateTime(let dateTime):
            guard let date = try? dateTime.value?.asNSDate() else {
                return nil
            }
            startDate = date
            endDate = date
        case .instant(let instant):
            guard let date = try? instant.value?.asNSDate() else {
                return nil
            }
            startDate = date
            endDate = date
        case .period(let period):
            guard let start = try? period.start?.value?.asNSDate(),
                  let end = try? period.end?.value?.asNSDate() else {
                return nil
            }
            startDate = start
            endDate = end
        case .timing:
            return nil
        }
        let sampleType: MHCQuantitySampleType
        if let sampleTypeHint {
            sampleType = sampleTypeHint
        } else if let healthKitCoding = coding.first(where: { $0.system == "http://developer.apple.com/documentation/healthkit" }) {
            guard let sampleTypeIdentifier = healthKitCoding.code?.value?.string,
                  let healthKitSampleType = SpeziHealthKit.SampleType<HKQuantitySample>(.init(rawValue: sampleTypeIdentifier)) else {
                return nil
            }
            sampleType = .healthKit(healthKitSampleType)
        } else if let mhcCustomTypeCoding = coding.first(where: { $0.system == "https://spezi.stanford.edu" }),
                  let identifier = mhcCustomTypeCoding.code?.value?.string,
                  let mhcSampleType = CustomQuantitySampleType(identifier: identifier) {
            sampleType = .custom(mhcSampleType)
        } else {
            // no hint and also we were unable to extract smth we know / can handle
            return nil
        }
        self.init(
            id: id,
            sampleType: sampleType,
            unit: unit,
            value: value,
            startDate: startDate,
            endDate: endDate
        )
    }
}
