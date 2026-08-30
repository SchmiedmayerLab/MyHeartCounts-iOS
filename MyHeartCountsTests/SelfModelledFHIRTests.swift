//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import FHIRModelsExtensions
import Foundation
import GroveHealthKit
import GroveHealthKitFHIR
import GroveStudyDefinition
import HealthKit
import ModelsR4
@testable import MyHeartCounts
import Testing


@Suite
struct SelfModelledQuantityFHIRTests {
    @Test
    func writerSeparatesClinicalCodeFromUCUMQuantity() throws {
        let sample = QuantitySample(
            id: UUID(),
            sampleType: .custom(.bloodLipids),
            unit: HKUnit.gram() / .liter(),
            value: 0.5,
            date: Date(timeIntervalSince1970: 1_788_000_000)
        )

        let resource = try sample.resource(issuedDate: nil, extensions: [])
        let observation = try #require(resource.get(if: Observation.self))
        guard case .quantity(let quantity) = observation.value else {
            Issue.record("Expected a quantity value")
            return
        }

        #expect(observation.id?.value?.string == sample.id.uuidString)
        #expect(observation.identifier == nil)
        let clinicalCoding = try #require(observation.code.coding?.first)
        #expect(clinicalCoding.system == LOINC.system)
        #expect(clinicalCoding.code?.value?.string == "18262-6")
        #expect(quantity.system == UCUM.system)
        #expect(quantity.code?.value?.string == "mg/dL")
        #expect(quantity.unit?.value?.string == "mg/dL")
        #expect(quantity.value?.value?.decimal.doubleValue == 50)
    }

    @Test
    func readerUsesUCUMCodeAndIgnoresDisplayText() throws {
        let observation = try bloodLipidsObservation(
            system: UCUM.system,
            code: "mg/dL",
            display: "this is not a HealthKit unit"
        )

        let sample = try #require(QuantitySample(observation))
        #expect(sample.hkQuantity().is(
            compatibleWith: HKUnit.gramUnit(with: .milli) / .literUnit(with: .deci)
        ))
        #expect(sample.value(as: sample.sampleType.canonicalUnit) == 50)
    }

    @Test
    func readerRejectsMissingWrongOrIncompatibleUCUMCoding() throws {
        #expect(QuantitySample(try bloodLipidsObservation(
            system: nil,
            code: "mg/dL",
            display: "mg/dL"
        )) == nil)
        #expect(QuantitySample(try bloodLipidsObservation(
            system: "https://example.com/not-ucum",
            code: "mg/dL",
            display: "mg/dL"
        )) == nil)
        #expect(QuantitySample(try bloodLipidsObservation(
            system: UCUM.system,
            code: "m",
            display: "mg/dL"
        )) == nil)
        var preliminary = try bloodLipidsObservation(
            system: UCUM.system,
            code: "mg/dL",
            display: "mg/dL"
        )
        preliminary.status = FHIRPrimitive(.preliminary)
        #expect(QuantitySample(preliminary) == nil)
    }

    @Test
    func writerRejectsIncompatibleSourceUnit() {
        let sample = QuantitySample(
            id: UUID(),
            sampleType: .custom(.bloodLipids),
            unit: .meter(),
            value: 50,
            date: Date(timeIntervalSince1970: 1_788_000_000)
        )

        #expect(throws: QuantitySample.FHIRObservationConversionError.incompatibleUnit(
            sampleTypeIdentifier: CustomQuantitySampleType.bloodLipids.id
        )) {
            _ = try sample.resource(issuedDate: nil, extensions: [])
        }
    }

    private func bloodLipidsObservation(
        system: FHIRPrimitive<FHIRURI>?,
        code: String?,
        display: String
    ) throws -> Observation {
        var observation = Observation(
            code: CodeableConcept(coding: [
                Coding(
                    code: CustomQuantitySampleType.bloodLipids.id.asFHIRStringPrimitive(),
                    system: MHCCodingSystem.system
                )
            ]),
            status: FHIRPrimitive(.final)
        )
        observation.id = UUID().uuidString.asFHIRStringPrimitive()
        let timeZone = try #require(TimeZone(secondsFromGMT: 0))
        try observation.setEffective(
            startDate: Date(timeIntervalSince1970: 1_788_000_000),
            endDate: Date(timeIntervalSince1970: 1_788_000_000),
            timeZone: timeZone
        )
        observation.value = .quantity(Quantity(
            code: code?.asFHIRStringPrimitive(),
            system: system,
            unit: display.asFHIRStringPrimitive(),
            value: 50.0.asFHIRDecimalPrimitive()
        ))
        return observation
    }
}


@Suite
struct TimedWalkingTestFHIRTests {
    @Test
    func writerUsesTypedLOINCComponentsAndUCUMQuantities() throws {
        let result = testResult()
        let observation = try result.fhirObservation(issuedDate: nil, extensions: [])

        #expect(observation.id?.value?.string == result.id.uuidString)
        #expect(observation.identifier == nil)
        let stepQuantity = try #require(quantity(in: observation, for: .pedometerNumStepsInUnspecifiedTime))
        #expect(stepQuantity.system == UCUM.system)
        #expect(stepQuantity.code?.value?.string == "{steps}")
        #expect(stepQuantity.value?.value?.decimal.doubleValue == 720)
        let distanceQuantity = try #require(quantity(in: observation, for: .pedometerWalkingDistanceInUnspecifiedTime))
        #expect(distanceQuantity.system == UCUM.system)
        #expect(distanceQuantity.code?.value?.string == "m")
        let durationQuantity = try #require(quantity(in: observation, for: .exerciseDuration))
        #expect(durationQuantity.system == UCUM.system)
        #expect(durationQuantity.code?.value?.string == "min")
    }

    @Test
    func readerRoundTripsTheStrictResource() throws {
        let result = testResult()
        let observation = try result.fhirObservation(issuedDate: nil, extensions: [])

        let decoded = try #require(TimedWalkingTestResult(observation))
        #expect(decoded == result)
    }

    @Test
    func readerRejectsDisplayOnlyAndIncompatibleComponentUnits() throws {
        let result = testResult()
        var displayOnly = try result.fhirObservation(issuedDate: nil, extensions: [])
        try replaceQuantity(in: &displayOnly, for: .exerciseDuration) { quantity in
            quantity.system = nil
            quantity.code = nil
            quantity.unit = "min".asFHIRStringPrimitive()
        }
        #expect(TimedWalkingTestResult(displayOnly) == nil)

        var incompatible = try result.fhirObservation(issuedDate: nil, extensions: [])
        try replaceQuantity(in: &incompatible, for: .pedometerWalkingDistanceInUnspecifiedTime) { quantity in
            quantity.code = "kg".asFHIRStringPrimitive()
            quantity.unit = "m".asFHIRStringPrimitive()
        }
        #expect(TimedWalkingTestResult(incompatible) == nil)
    }

    @Test
    func readerRequiresLOINCSystemsAndIntegralSteps() throws {
        let result = testResult()
        var wrongSystem = try result.fhirObservation(issuedDate: nil, extensions: [])
        let index = try componentIndex(in: wrongSystem, for: .exerciseActivity)
        var components = try #require(wrongSystem.component)
        var codings = try #require(components[index].code.coding)
        codings[0].system = "https://example.com/not-loinc".asFHIRURIPrimitive()
        components[index].code.coding = codings
        wrongSystem.component = components
        #expect(TimedWalkingTestResult(wrongSystem) == nil)

        var fractionalSteps = try result.fhirObservation(issuedDate: nil, extensions: [])
        try replaceQuantity(in: &fractionalSteps, for: .pedometerNumStepsInUnspecifiedTime) { quantity in
            quantity.value = 720.5.asFHIRDecimalPrimitive()
        }
        #expect(TimedWalkingTestResult(fractionalSteps) == nil)
    }

    private func testResult() -> TimedWalkingTestResult {
        let start = Date(timeIntervalSince1970: 1_788_000_000)
        return TimedWalkingTestResult(
            id: UUID(),
            test: .sixMinuteWalkTest,
            startDate: start,
            endDate: start.addingTimeInterval(360),
            numberOfSteps: 720,
            distanceCovered: 612.5
        )
    }

    private func quantity(in observation: Observation, for loinc: LOINC) -> Quantity? {
        guard let component = observation.component?.first(where: {
            $0.code.coding?.contains { $0.system == LOINC.system && $0.code == loinc.code } == true
        }), case .quantity(let quantity) = component.value else {
            return nil
        }
        return quantity
    }

    private func componentIndex(in observation: Observation, for loinc: LOINC) throws -> Int {
        try #require(observation.component?.firstIndex {
            $0.code.coding?.contains { $0.system == LOINC.system && $0.code == loinc.code } == true
        })
    }

    private func replaceQuantity(
        in observation: inout Observation,
        for loinc: LOINC,
        mutation: (inout Quantity) -> Void
    ) throws {
        let index = try componentIndex(in: observation, for: loinc)
        guard case .quantity(var quantity) = observation.component?[index].value else {
            Issue.record("Expected quantity component")
            return
        }
        mutation(&quantity)
        var components = try #require(observation.component)
        components[index].value = .quantity(quantity)
        observation.component = components
    }
}
