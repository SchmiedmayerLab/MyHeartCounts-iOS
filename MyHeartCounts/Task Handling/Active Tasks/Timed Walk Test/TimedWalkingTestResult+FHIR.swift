//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import CoreMotion
import FHIRModelsExtensions
import Foundation
import GroveFoundation
import GroveHealthKitFHIR
import GroveStudyDefinition
import HealthKit
import ModelsR4
import MyHeartCountsShared


extension TimedWalkingTestResult {
    enum FHIRObservationConversionError: Error, Equatable {
        case invalidDistance
        case invalidDuration
        case invalidStepCount
    }

    func resource(
        issuedDate: ModelsR4.FHIRPrimitive<ModelsR4.Instant>?,
        extensions: [any FHIRExtensionBuilderProtocol]
    ) throws -> ModelsR4.ResourceProxy {
        .observation(try fhirObservation(issuedDate: issuedDate, extensions: extensions))
    }
    
    
    func fhirObservation( // swiftlint:disable:this function_body_length
        issuedDate: ModelsR4.FHIRPrimitive<ModelsR4.Instant>?,
        extensions: [any FHIRExtensionBuilderProtocol]
    ) throws -> Observation {
        guard numberOfSteps >= 0 else {
            throw FHIRObservationConversionError.invalidStepCount
        }
        guard distanceCovered.isFinite, distanceCovered >= 0 else {
            throw FHIRObservationConversionError.invalidDistance
        }
        let durationInMinutes = test.duration.timeInterval / 60
        guard durationInMinutes.isFinite, durationInMinutes > 0 else {
            throw FHIRObservationConversionError.invalidDuration
        }
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
        if test == .sixMinuteWalkTest {
            observation.append(coding: Coding(code: LOINC.phenXSixMinuteWalkTest))
            observation.append(component: .init(
                code: LOINC.sixMinuteWalkTest,
                quantityUnit: .ucum(code: "m"),
                quantityValue: distanceCovered
            ))
        }
        observation.append(coding: Coding(code: LOINC.pedometerTrackingPanel))
        observation.append(component: .init(
            code: LOINC.pedometerNumStepsInUnspecifiedTime,
            quantityUnit: .ucum(code: "{steps}", display: "steps"),
            quantityValue: Double(numberOfSteps)
        ))
        observation.append(component: .init(
            code: LOINC.pedometerWalkingDistanceInUnspecifiedTime,
            quantityUnit: .ucum(code: "m"),
            quantityValue: distanceCovered
        ))
        // we also append the duration and the activity type
        // in the case of the six-minute walk test, this is redundant, but for all other cases it's important.
        observation.append(component: .init(
            code: LOINC.exerciseDuration,
            quantityUnit: .ucum(code: "min"),
            quantityValue: durationInMinutes
        ))
        observation.append(component: .init(
            code: CodeableConcept(coding: [Coding(code: LOINC.exerciseActivity)]),
            value: .codeableConcept(CodeableConcept(coding: [
                Coding(code: { () -> LOINC in
                    switch test.kind {
                    case .walking: .exerciseActivityWalking
                    case .running: .exerciseActivityRunning
                    }
                }())
            ]))
        ))
        for builder in extensions {
            try builder.apply(typeErasedInput: self, to: &observation)
        }
        return observation
    }
}


extension TimedWalkingTestResult {
    init?(_ observation: ModelsR4.Observation) {
        guard observation.status.value == .final,
              observation.hasLOINCCode(.pedometerTrackingPanel),
              let id = (observation.id?.value?.string).flatMap({ UUID(uuidString: $0) }),
              let timeRange = try? observation.effectiveTimePeriod,
              timeRange.lowerBound < timeRange.upperBound,
              let duration = observation.quantityValue(.exerciseDuration, in: .minute()),
              duration > 0,
              let rawStepCount = observation.quantityValue(.pedometerNumStepsInUnspecifiedTime, in: .count()),
              rawStepCount >= 0,
              let numSteps = Int(exactly: rawStepCount),
              let distance = observation.quantityValue(.pedometerWalkingDistanceInUnspecifiedTime, in: .meter()),
              distance >= 0,
              let activityCoding = observation.codeableConceptValue(.exerciseActivity)?.coding?.first(where: {
                  $0.system == LOINC.system
              })?.code,
              let activity = TimedWalkingTestConfiguration.Kind(LOINC(activityCoding)) else {
            return nil
        }
        self.init(
            id: id,
            test: .init(duration: .minutes(duration), kind: activity),
            startDate: timeRange.lowerBound,
            endDate: timeRange.upperBound,
            numberOfSteps: numSteps,
            distanceCovered: distance
        )
    }
}


extension Observation {
    var effectiveTimePeriod: Swift.Range<Date>? {
        get throws {
            switch effective {
            case nil:
                nil
            case .dateTime(let dateTime):
                try (dateTime.value?.asNSDate()).map { $0..<$0 }
            case .instant(let instant):
                try (instant.value?.asNSDate()).map { $0..<$0 }
            case .period(let period):
                if let start = period.start?.value, let end = period.end?.value {
                    try start.asNSDate()..<end.asNSDate()
                } else {
                    nil
                }
            case .timing:
                // currently unsupported
                nil
            }
        }
    }

    fileprivate func hasLOINCCode(_ loinc: LOINC) -> Bool {
        code.coding?.contains {
            $0.system == LOINC.system && $0.code == loinc.code
        } == true
    }

    private func component(_ loinc: LOINC) -> ObservationComponent? {
        component?.first {
            $0.code.coding?.contains {
                $0.system == LOINC.system && $0.code == loinc.code
            } == true
        }
    }

    fileprivate func quantityValue(_ loinc: LOINC, in expectedUnit: HKUnit) -> Double? {
        guard case .quantity(let quantity) = component(loinc)?.value,
              quantity.system == UCUM.system,
              let code = quantity.code?.value?.string,
              let unit = HealthKitCatalog.unit(forUCUMCode: code),
              let value = quantity.value?.value?.decimal.doubleValue else {
            return nil
        }
        let healthKitQuantity = HKQuantity(unit: unit, doubleValue: value)
        guard healthKitQuantity.is(compatibleWith: expectedUnit) else {
            return nil
        }
        return healthKitQuantity.doubleValue(for: expectedUnit)
    }

    fileprivate func codeableConceptValue(_ loinc: LOINC) -> CodeableConcept? {
        guard case .codeableConcept(let codeableConcept) = component(loinc)?.value else {
            return nil
        }
        return codeableConcept
    }
}


extension TimedWalkingTestConfiguration.Kind {
    init?(_ loinc: LOINC) {
        switch loinc {
        case .exerciseActivityWalking:
            self = .walking
        case .exerciseActivityRunning:
            self = .running
        default:
            return nil
        }
    }
}
