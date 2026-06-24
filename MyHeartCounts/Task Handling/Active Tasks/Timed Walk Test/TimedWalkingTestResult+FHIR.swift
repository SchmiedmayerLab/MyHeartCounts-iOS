//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import CoreMotion
import FHIRModelsExtensions
import Foundation
import HealthKitOnFHIR
import ModelsR4
import MyHeartCountsShared
import SpeziFoundation
import SpeziStudyDefinition


extension TimedWalkingTestResult {
    func resource(
        withMapping: HealthKitOnFHIR.HKSampleMapping,
        issuedDate: ModelsR4.FHIRPrimitive<ModelsR4.Instant>?,
        extensions: [any FHIRExtensionBuilderProtocol]
    ) throws -> ModelsR4.ResourceProxy {
        .observation(try fhirObservation(issuedDate: issuedDate, extensions: extensions))
    }
    
    
    func fhirObservation( // swiftlint:disable:this function_body_length
        issuedDate: ModelsR4.FHIRPrimitive<ModelsR4.Instant>?,
        extensions: [any FHIRExtensionBuilderProtocol]
    ) throws -> Observation {
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
        if test == .sixMinuteWalkTest {
            observation.appendCoding(Coding(code: LOINC.phenXSixMinuteWalkTest))
            observation.appendComponent(.init(
                code: LOINC.sixMinuteWalkTest,
                quantityUnit: "m",
                quantityValue: distanceCovered
            ))
        }
        observation.appendCoding(Coding(code: LOINC.pedometerTrackingPanel))
        observation.appendComponent(.init(
            code: LOINC.pedometerNumStepsInUnspecifiedTime,
            quantityUnit: "count",
            quantityValue: Double(numberOfSteps)
        ))
        observation.appendComponent(.init(
            code: LOINC.pedometerWalkingDistanceInUnspecifiedTime,
            quantityUnit: "m",
            quantityValue: distanceCovered
        ))
        // we also append the duration and the activity type
        // in the case of the six-minute walk test, this is redundant, but for all other cases it's important.
        observation.appendComponent(.init(
            code: LOINC.exerciseDuration,
            quantityUnit: "min",
            quantityValue: test.duration.timeInterval / 60
        ))
        observation.appendComponent(.init(
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
            try builder.apply(typeErasedInput: self, to: observation)
        }
        observation.addMHCAppAsSource()
        return observation
    }
}


extension TimedWalkingTestResult {
    init?(_ observation: ModelsR4.Observation) {
        func getComponent(_ loinc: LOINC) -> ObservationComponent? {
            observation.component?.first { ($0.code.coding ?? []).contains { $0.code == loinc.code } }
        }
        func getQuantityValue(_ loinc: LOINC) -> Decimal? {
            switch getComponent(loinc)?.value {
            case .quantity(let quantity):
                quantity.value?.value?.decimal
            default:
                nil
            }
        }
        func getCodeableConceptValue(_ loinc: LOINC) -> CodeableConcept? {
            switch getComponent(loinc)?.value {
            case .codeableConcept(let codeableConcept):
                codeableConcept
            default:
                nil
            }
        }
        guard let id = (observation.id?.value?.string).flatMap({ UUID(uuidString: $0) }),
              let timeRange = try? observation.effectiveTimePeriod,
              let duration = getQuantityValue(.exerciseDuration)?.doubleValue,
              let numSteps = getQuantityValue(.pedometerNumStepsInUnspecifiedTime)?.intValue,
              let distance = getQuantityValue(.pedometerWalkingDistanceInUnspecifiedTime)?.doubleValue,
              let activity = (getCodeableConceptValue(.exerciseActivity)?.coding?.first?.code).map({ LOINC($0) }),
              let activity = TimedWalkingTestConfiguration.Kind(activity) else {
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


extension Decimal {
    var intValue: Int {
        Int(self)
    }
}
