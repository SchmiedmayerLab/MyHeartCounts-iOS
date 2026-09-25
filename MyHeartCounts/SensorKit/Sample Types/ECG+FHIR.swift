//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import FHIRModelsExtensions
import Foundation
import GroveHealthKitFHIR
import GroveSensorKit
import ModelsR4


extension SensorKitECGSession: HealthObservation {
    var id: UUID {
        var hasher = SensorKitSampleIDHasher()
        hasher.combine(sampleTypeIdentifier)
        hasher.combine(timeRange.lowerBound)
        hasher.combine(duration)
        hasher.combine(frequency.value)
        hasher.combine(batches.count)
        for batch in batches {
            hasher.combine(batch.offset)
            hasher.combine(batch.samples.count)
            for sample in batch.samples {
                hasher.combine(sample.voltage.value)
            }
        }
        return hasher.finalize()
    }
    
    var sampleTypeIdentifier: String {
        Sensor.ecg.id
    }
    
    func resource( // swiftlint:disable:this function_body_length
        withMapping mapping: SampleTypesFHIRMapping,
        issuedDate: FHIRPrimitive<Instant>?,
        extensions: [any FHIRExtensionBuilderProtocol]
    ) throws -> ResourceProxy {
        let ecgMapping = mapping.ecgTypeMapping
        var observation = Observation(
            code: CodeableConcept(),
            status: FHIRPrimitive(.final)
        )
        observation.id = self.id.uuidString.asFHIRStringPrimitive()
        observation.append(coding: Coding(code: SensorKitCodingSystem(.ecg)))
        observation.append(identifier: Identifier(id: observation.id))
        if let issuedDate {
            observation.issued = issuedDate
        } else {
            try observation.setIssued(on: .now)
        }
        observation.effective = try .period(Period(
            end: FHIRPrimitive(DateTime(date: timeRange.upperBound)),
            start: FHIRPrimitive(DateTime(date: timeRange.lowerBound))
        ))
        let ecgCodableConcept = CodeableConcept(
            coding: ecgMapping.codings.map { mappedCode -> Coding in
                Coding(
                    code: mappedCode.code,
                    display: mappedCode.display,
                    system: mappedCode.system
                )
            }
        )
        for coding in ecgCodableConcept.coding ?? [] {
            observation.append(coding: coding)
        }
        for category in ecgMapping.categories {
            observation.append(
                category: CodeableConcept(coding: [
                    Coding(
                        code: category.code,
                        display: category.display,
                        system: category.system
                    )
                ])
            )
        }
        let precision = ecgMapping.voltagePrecision
        // "zero value and unit"
        let origin = Quantity(
            code: ecgMapping.voltageMeasurements.unit.code,
            system: ecgMapping.voltageMeasurements.unit.system,
            unit: ecgMapping.voltageMeasurements.unit.unit.asFHIRStringPrimitive(),
            value: 0.asFHIRDecimalPrimitive()
        )
        for batch in batches {
            observation.append(component: ObservationComponent(
                code: ecgCodableConcept,
                value: .sampledData(SampledData(
                    data: batch.samples.lazy.map { sample in
                        let value = sample.voltage.converted(to: .microvolts).value
                        return String(format: "%.\(precision)f", value)
                    }.joined(separator: " ").asFHIRStringPrimitive(), // swiftlint:disable:this multiline_function_chains
                    dimensions: 1,
                    lowerLimit: nil,
                    origin: origin,
                    period: ((1 / frequency.converted(to: .hertz).value) * 1000).asFHIRDecimalPrimitive(), // ms between samples
                    upperLimit: nil
                ))
            ))
        }
        for builder in extensions {
            try builder.apply(typeErasedInput: self, to: &observation)
        }
        observation.addMHCAppAsSource()
        return .observation(observation)
    }
}
