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
@testable import MyHeartCounts
import SpeziFoundation
import SpeziHealthKit
import Testing


@Suite
struct HealthSampleProcessingTests {
    // check that the zstd-compressed FHIR-encoded Health samples can be decompressed and decoded and have the correct values.
    // note that this test is only very barebones; we have more inp-depth testing for this in HealthKitOnFHIR.
    @Test
    func healthKitSamplesProcessing() async throws {
        let startDate = Date()
        func makeSample(numSteps: Int, startOffset: TimeInterval, duration: TimeInterval) -> HKQuantitySample {
            HKQuantitySample(
                type: SampleType.stepCount.hkSampleType,
                quantity: HKQuantity(unit: .count(), doubleValue: Double(numSteps)),
                start: startDate + startOffset,
                end: startDate + startOffset + duration
            )
        }
        let samples = [
            makeSample(numSteps: 12, startOffset: 0, duration: 10),
            makeSample(numSteps: 7, startOffset: 15, duration: 10),
            makeSample(numSteps: 9, startOffset: 27, duration: 12)
        ]
        let processor = HealthKitSamplesFHIRUploader(standard: nil)
        let compressedUrl = try #require(await processor.process(samples, of: .stepCount))
        let decompressed = try Data(contentsOf: compressedUrl).decompressed(using: Zstd.self)
        let observations = try JSONDecoder().decode([Observation].self, from: decompressed)
        #expect(observations.count == 3)
        #expect(observations.map(\.quantityValue) == [
            HKQuantity(unit: .count(), doubleValue: 12),
            HKQuantity(unit: .count(), doubleValue: 7),
            HKQuantity(unit: .count(), doubleValue: 9)
        ])
    }
    
    
    @Test
    func fhirUnitToHKUnit() {
        #expect(HKUnit.parseFromFHIRUnit("steps") == .count())
        #expect(HKUnit.parseFromFHIRUnit("/min") == HKUnit.count() / .minute())
        #expect(HKUnit.parseFromFHIRUnit("beats/minute") == HKUnit.count() / .minute())
        
        #expect(HKUnit.parseFromFHIRUnit("Cel") == .degreeCelsius())
        #expect(HKUnit.parseFromFHIRUnit("C") == .degreeCelsius())
    }
    
    
    @Test
    func hkUnitParsing() {
        #expect(HKUnit.parse("degC") == .degreeCelsius())
        #expect(HKUnit.parse("Cel") == .degreeCelsius())
        #expect(HKUnit.parse("C") == .degreeCelsius())
    }
    
    
    @Test
    func customQuantitySampleToFHIR() throws {
        let now = Date()
        let sample = QuantitySample(
            id: UUID(),
            sampleType: .custom(.bloodLipids),
            unit: QuantitySample.SampleType.custom(.bloodLipids).displayUnit, // mg / dL
            value: 50,
            startDate: now,
            endDate: now
        )
        let resource = try sample.resource(withMapping: .default, issuedDate: nil, extensions: [])
        let observation = try #require(resource.get(if: Observation.self))
        #expect(observation.quantityValue == HKQuantity(unit: .gramUnit(with: .milli) / .literUnit(with: .deci), doubleValue: 50))
        #expect(observation.id == sample.id.uuidString.asFHIRStringPrimitive())
        switch observation.effective {
        case .dateTime(let dateTime):
            let dateTime = try #require(dateTime.value)
            #expect(try dateTime.asNSDate() == sample.startDate)
        default:
            Issue.record()
        }
    }
    
    
    @Test
    func hkSampleUploadTimeZone() throws {
        let sample = HKQuantitySample(
            type: .init(.heartRate),
            quantity: HKQuantity(unit: .count() / .minute(), doubleValue: 85),
            start: .now,
            end: .now
        )
        let resource = try sample.resource(extensions: [.sampleUploadTimeZone])
        let observation = try #require(resource.get(if: Observation.self))
        let ext = try #require(observation.extensions(for: FHIRExtensionUrls.sampleUploadTimeZone).first)
        switch try #require(ext.value) {
        case .string(let string):
            #expect(string.value?.string == TimeZone.current.identifier)
        default:
            Issue.record("Invalid value")
        }
    }
}


extension Observation {
    var quantityValue: HKQuantity? {
        switch value {
        case .quantity(let quantity):
            if let value = quantity.value?.value?.decimal.doubleValue,
               let unit = (quantity.unit?.value?.string).flatMap({ HKUnit.parseFromFHIRUnit($0) }) {
                HKQuantity(unit: unit, doubleValue: value)
            } else {
                nil
            }
        default:
            nil
        }
    }
}
