//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import FHIRModelsExtensions
import Foundation
import GroveFoundation
import GroveHealthKit
import GroveHealthKitFHIR
import HealthKit
import ModelsR4
import MyHeartCountsShared


extension QuantitySample: SelfModelledHealthObservation {
    enum FHIRObservationConversionError: Error, Equatable {
        case incompatibleUnit(sampleTypeIdentifier: String)
        case notSupported
    }

    private struct FHIRQuantityBinding {
        let code: String
        let display: String
        let unit: HKUnit
    }
    
    var sampleTypeIdentifier: String {
        self.sampleType.id
    }
    
    // swiftlint:disable:next function_body_length
    func resource(
        issuedDate: FHIRPrimitive<Instant>?,
        extensions: [any FHIRExtensionBuilderProtocol]
    ) throws -> ResourceProxy {
        var observation = Observation(
            code: CodeableConcept(),
            status: FHIRPrimitive(.final)
        )
        // Set basic elements applicable to all observations
        observation.id = self.id.uuidString.asFHIRStringPrimitive()
        try observation.setEffective(startDate: self.startDate, endDate: self.endDate, timeZone: .current)
        if let issuedDate {
            observation.issued = issuedDate
        } else {
            try observation.setIssued(on: .now)
        }
        switch sampleType {
        case .healthKit:
            // A HealthKit-typed entry is saved to HealthKit and converted from the stored sample by the
            // Grove adapter. Converting this dashboard reconstruction instead would assert a recording
            // device and provenance it never had.
            throw FHIRObservationConversionError.notSupported
        case .custom(.bloodLipids):
            let observationCode = "18262-6".asFHIRStringPrimitive()
            let observationSystem = "http://loinc.org".asFHIRURIPrimitive()
            observation.append(codings: [
                Coding(code: observationCode, system: observationSystem),
                Coding(
                    code: sampleType.id.asFHIRStringPrimitive(),
                    display: sampleType.displayTitle.asFHIRStringPrimitive(),
                    system: MHCCodingSystem.system
                )
            ])
            observation.value = .quantity(try fhirQuantity(
                binding: .init(
                    code: "mg/dL",
                    display: "mg/dL",
                    unit: .gramUnit(with: .milli) / .literUnit(with: .deci)
                )
            ))
        case .custom(.nicotineExposure), .custom(.dietMEPAScore), .custom(.mentalWellbeingScore):
            let code = sampleType.id.asFHIRStringPrimitive()
            observation.append(coding: Coding(
                code: code,
                display: sampleType.displayTitle.asFHIRStringPrimitive(),
                system: MHCCodingSystem.system
            ))
            observation.value = .quantity(try fhirQuantity(binding: .init(
                code: "{score}",
                display: "score",
                unit: .count()
            )))
        default:
            throw FHIRObservationConversionError.notSupported
        }
        for builder in extensions {
            try builder.apply(typeErasedInput: self, to: &observation)
        }
        return .observation(observation)
    }

    private func fhirQuantity(binding: FHIRQuantityBinding) throws -> Quantity {
        let quantity = HKQuantity(unit: unit, doubleValue: value)
        guard quantity.is(compatibleWith: binding.unit) else {
            throw FHIRObservationConversionError.incompatibleUnit(sampleTypeIdentifier: sampleTypeIdentifier)
        }
        return Quantity(
            code: binding.code.asFHIRStringPrimitive(),
            system: UCUM.system,
            unit: binding.display.asFHIRStringPrimitive(),
            value: quantity.doubleValue(for: binding.unit).asFHIRDecimalPrimitive()
        )
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
        guard observation.status.value == .final,
              let id = (observation.id?.value?.string).flatMap({ UUID(uuidString: $0) }),
              case .quantity(let quantity) = observation.value,
              quantity.system == UCUM.system,
              let ucumCode = quantity.code?.value?.string,
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
                  let healthKitSampleType = GroveHealthKit.SampleType<HKQuantitySample>(.init(rawValue: sampleTypeIdentifier)) else {
                return nil
            }
            sampleType = .healthKit(healthKitSampleType)
        } else if let mhcCustomTypeCoding = coding.first(where: { coding in
            MHCCodingSystem.allSystems.contains { $0 == coding.system }
        }),
                  let identifier = mhcCustomTypeCoding.code?.value?.string,
                  let mhcSampleType = CustomQuantitySampleType(identifier: identifier) {
            sampleType = .custom(mhcSampleType)
        } else {
            // no hint and also we were unable to extract smth we know / can handle
            return nil
        }
        let unit: HKUnit?
        switch sampleType {
        case .custom(.nicotineExposure), .custom(.dietMEPAScore), .custom(.mentalWellbeingScore):
            // MHC scores predate a Grove profile, so their unit bindings stay local; every shared
            // clinical unit is resolved only through Grove's generated catalog. The app writes
            // `{score}`, the backend scoring functions write `{count}`, as every stored score does.
            guard ucumCode == "{score}" || ucumCode == "{count}" else {
                return nil
            }
            unit = .count()
        default:
            unit = HealthKitCatalog.unit(forUCUMCode: ucumCode)
        }
        guard let unit,
              HKQuantity(unit: unit, doubleValue: value).is(compatibleWith: sampleType.displayUnit) else {
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
