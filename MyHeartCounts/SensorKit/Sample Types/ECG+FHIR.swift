//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import SpeziHealthKitFHIR
import ModelsR4
import SpeziSensorKit
import FHIRModelsExtensions


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
        withMapping mapping: HKSampleMapping,
        issuedDate: FHIRPrimitive<Instant>?,
        extensions: [any FHIRExtensionBuilderProtocol]
    ) throws -> ResourceProxy {
        let ecgMapping = mapping.electrocardiogramMapping
        let observation = Observation(
            code: CodeableConcept(),
            status: FHIRPrimitive(.final)
        )
        observation.id = self.id.uuidString.asFHIRStringPrimitive()
        observation.appendCoding(Coding(code: SensorKitCodingSystem(.ecg)))
        observation.appendIdentifier(Identifier(id: observation.id))
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
                    code: mappedCode.code.asFHIRStringPrimitive(),
                    display: mappedCode.display.asFHIRStringPrimitive(),
                    system: mappedCode.system.asFHIRURIPrimitive()
                )
            }
        )
        for coding in ecgCodableConcept.coding ?? [] {
            observation.appendCoding(coding)
        }
        for category in ecgMapping.categories {
            observation.appendCategory(
                CodeableConcept(coding: [
                    Coding(
                        code: category.code.asFHIRStringPrimitive(),
                        display: category.display.asFHIRStringPrimitive(),
                        system: category.system.asFHIRURIPrimitive()
                    )
                ])
            )
        }
        let precision = ecgMapping.voltagePrecision
        // "zero value and unit"
        let origin = Quantity(
            code: ecgMapping.voltageMeasurements.unit.code?.asFHIRStringPrimitive(),
            system: ecgMapping.voltageMeasurements.unit.system?.asFHIRURIPrimitive(),
            unit: ecgMapping.voltageMeasurements.unit.unit.asFHIRStringPrimitive(),
            value: 0.asFHIRDecimalPrimitive()
        )
        for batch in batches {
            observation.appendComponent(ObservationComponent(
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
            try builder.apply(typeErasedInput: self, to: observation)
        }
        observation.addMHCAppAsSource()
        return .observation(observation)
    }
}
