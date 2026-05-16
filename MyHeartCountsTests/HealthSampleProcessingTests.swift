//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import AsyncAlgorithms
import Foundation
import HealthKit
import HealthKitOnFHIR
import ModelsR4
@testable import MyHeartCounts
@testable import MyHeartCountsShared
import Spezi
import SpeziFoundation
import SpeziHealthKit
import SpeziTesting
import Testing


@Suite
struct HealthSampleProcessingTests {
    private actor FakeStandard: Standard, HealthKitConstraint {
        func handleNewSamples<Sample>(_ addedSamples: some Collection<Sample> & Sendable, ofType sampleType: SampleType<Sample>) {}
        func handleDeletedObjects<Sample>(_ deletedObjects: some Collection<HKDeletedObject> & Sendable, ofType sampleType: SampleType<Sample>) {}
    }
    
    
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
    
    
    @Test
    func healthUploadStagingDuplicates() async throws {
        let healthUploadStaging = HealthUploadStaging(persistence: .inMemory)
        await withDependencyResolution(standard: FakeStandard()) {
            healthUploadStaging
            HealthKit()
        }
        #expect(try healthUploadStaging.isEmpty)
        
        let cal = Calendar.current
        let samplesStartDate = try #require(cal.date(from: .init(year: 2026, month: 5, day: 9, hour: 17, minute: 52)))
        let samplesEndDate = try #require(cal.date(from: .init(year: 2026, month: 5, day: 9, hour: 17, minute: 57)))
        
        #expect(try healthUploadStaging.isEmpty == true)
        let newSamples: [HKQuantitySample] = [
            HKQuantitySample(
                type: .init(.stepCount),
                quantity: HKQuantity(unit: .count(), doubleValue: 52),
                start: samplesStartDate,
                end: samplesEndDate
            ),
            HKQuantitySample(
                type: .init(.heartRate),
                quantity: HKQuantity(unit: .count() / .minute(), doubleValue: 91),
                start: samplesStartDate,
                end: samplesEndDate
            )
        ]
        
        try await healthUploadStaging.add(newSamples)
        #expect(try healthUploadStaging.fetchCount(of: HealthUploadStaging.PendingSampleRecord.self) == 2)
        #expect(try healthUploadStaging.fetchCount(of: HealthUploadStaging.PendingDeletionRecord.self) == 0)
        
        try await healthUploadStaging.add(newSamples)
        #expect(try healthUploadStaging.fetchCount(of: HealthUploadStaging.PendingSampleRecord.self) == 2)
        #expect(try healthUploadStaging.fetchCount(of: HealthUploadStaging.PendingDeletionRecord.self) == 0)
    }
    
    
    @Test
    func healthUploadStagingSanpleElision() async throws {
        let healthUploadStaging = HealthUploadStaging(persistence: .inMemory)
        await withDependencyResolution(standard: FakeStandard()) {
            healthUploadStaging
            HealthKit()
        }
        #expect(try healthUploadStaging.isEmpty)
        #expect(try healthUploadStaging.isEmpty)
        
        let cal = Calendar.current
        let samplesStartDate = try #require(cal.date(from: .init(year: 2026, month: 5, day: 9, hour: 17, minute: 52)))
        let samplesEndDate = try #require(cal.date(from: .init(year: 2026, month: 5, day: 9, hour: 17, minute: 57)))
        
        #expect(try healthUploadStaging.isEmpty == true)
        let newSamples: [HKQuantitySample] = [
            HKQuantitySample(
                type: .init(.stepCount),
                quantity: HKQuantity(unit: .count(), doubleValue: 52),
                start: samplesStartDate,
                end: samplesEndDate
            ),
            HKQuantitySample(
                type: .init(.heartRate),
                quantity: HKQuantity(unit: .count() / .minute(), doubleValue: 91),
                start: samplesStartDate,
                end: samplesEndDate
            )
        ]
        
        try await healthUploadStaging.add(newSamples)
        #expect(try healthUploadStaging.fetchCount(of: HealthUploadStaging.PendingSampleRecord.self) == 2)
        #expect(try healthUploadStaging.fetchCount(of: HealthUploadStaging.PendingDeletionRecord.self) == 0)
        
        try healthUploadStaging.add([try HKDeletedObject.make(uuid: newSamples[0].uuid)], ofType: .stepCount)
        try healthUploadStaging.elidePendingUploadsWherePossible(dryRun: false)
        #expect(try healthUploadStaging.fetchCount(of: HealthUploadStaging.PendingSampleRecord.self) == 1)
        #expect(try healthUploadStaging.fetchCount(of: HealthUploadStaging.PendingDeletionRecord.self) == 0)
        
        try healthUploadStaging.add([try HKDeletedObject.make(uuid: UUID())], ofType: .bodyMass)
        try healthUploadStaging.elidePendingUploadsWherePossible(dryRun: false)
        #expect(try healthUploadStaging.fetchCount(of: HealthUploadStaging.PendingSampleRecord.self) == 1)
        #expect(try healthUploadStaging.fetchCount(of: HealthUploadStaging.PendingDeletionRecord.self) == 1)
    }
    
    
    @Test
    func healthUploadStagingJSONPersistence() async throws {
        let healthKit = HealthKit()
        let healthUploadStaging = HealthUploadStaging(persistence: .inMemory)
        await withDependencyResolution(standard: FakeStandard()) {
            healthUploadStaging
            healthKit
        }
        #expect(try healthUploadStaging.isEmpty)
        
        let cal = Calendar.current
        let samplesStartDate = try #require(cal.date(from: .init(year: 2026, month: 5, day: 9, hour: 17, minute: 52)))
        let samplesEndDate = try #require(cal.date(from: .init(year: 2026, month: 5, day: 9, hour: 17, minute: 57)))
        
        let newSamples: [HKQuantitySample] = [
            HKQuantitySample(
                type: .init(.stepCount),
                quantity: HKQuantity(unit: .count(), doubleValue: 52),
                start: samplesStartDate,
                end: samplesEndDate
            ),
            HKQuantitySample(
                type: .init(.heartRate),
                quantity: HKQuantity(unit: .count() / .minute(), doubleValue: 91),
                start: samplesStartDate,
                end: samplesEndDate
            )
        ]
        let timestamp = Date()
        nonisolated(unsafe) let issuedDate = try ModelsR4.FHIRPrimitive<ModelsR4.Instant>(.init(date: timestamp))
        let samplesAsFHIR: Set<ModelsR4.ResourceProxy> = try await newSamples.async.reduce(into: []) { @Sendable result, observation in
            // ISSUE: we get back an `AnyEncodable` (bc the return type might be a ResourceProxy or an Observation or a R4/DSTU2 FHIRResource)
            // but we need these as `ModelsR4.ResourceProxy`s, so we need to do a quick JSON roundtrip to turn them into ResourceProxies (will work for everything except ClinicalRecords, but we don't have any of these anyway...
            let encodable = try await observation.turnIntoFHIRResource(issuedDate: issuedDate, using: healthKit)
            let encoded = try JSONEncoder().encode(encodable)
            let decoded = try JSONDecoder().decode(ModelsR4.ResourceProxy.self, from: encoded)
            result.insert(decoded)
        }
        try await healthUploadStaging.add(newSamples, ingestionTimestamp: timestamp)
        #expect(try healthUploadStaging.fetchCount(of: HealthUploadStaging.PendingSampleRecord.self) == 2)
        #expect(try healthUploadStaging.fetchCount(of: HealthUploadStaging.PendingDeletionRecord.self) == 0)
        let drainFetchResult = try healthUploadStaging.drainData(in: ..<(.now))
        #expect(drainFetchResult.deletions.isEmpty)
        #expect(drainFetchResult.samples.count == 2)
        #expect(drainFetchResult.samples.mapIntoSet(\.sampleType) == [SampleType.stepCount.id, SampleType.heartRate.id])
        let allDecodedSamples: Set<ModelsR4.ResourceProxy> = try drainFetchResult.samples.reduce(into: []) { result, batch in
            let jsonArray = try batch.rows.jsonArray()
            let resources = try JSONDecoder().decode(Set<ModelsR4.ResourceProxy>.self, from: jsonArray)
            result.formUnion(resources)
        }
        #expect(allDecodedSamples == samplesAsFHIR)
    }
}


extension HKDeletedObject {
    static func make(uuid: UUID) throws -> HKDeletedObject {
        // swiftlint:disable legacy_objc_type
        let sel = Selector(("_deletedObjectWithUUID:metadata:"))
        let imp = method_getImplementation(try #require(class_getClassMethod(HKDeletedObject.self, sel)))
        typealias Fun = @convention(c) (HKDeletedObject.Type, Selector, NSUUID, NSDictionary?) -> HKDeletedObject
        let fun = unsafeBitCast(imp, to: Fun.self)
        return fun(self, sel, uuid as NSUUID, nil)
        // swiftlint:enable legacy_objc_type
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
