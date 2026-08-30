//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import AsyncAlgorithms
import FHIRModelsExtensions
import Foundation
import Grove
import GroveFoundation
import GroveHealthKit
import GroveHealthKitFHIR
import GroveTesting
import HealthKit
import ModelsR4
@testable import MyHeartCounts
@testable import MyHeartCountsShared
import Testing


@Suite
struct HealthSampleProcessingTests { // swiftlint:disable:this type_body_length
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
        let compressedUrl = try processor.encodeSamples(samples, of: .stepCount)
        defer {
            try? FileManager.default.removeItem(at: compressedUrl)
        }
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
        let ext = try #require(observation.extensions(for: FHIRExtensionURL.sampleUploadTimeZone).first)
        switch try #require(ext.value) {
        case .string(let string):
            #expect(string.value?.string == TimeZone.current.identifier)
        default:
            Issue.record("Invalid value")
        }
    }
    

    /// Every FHIR resource the app creates must identify the MHC build which created it.
    @Test
    func mhcAppRevisionIsPartOfTheDefaultExtensions() throws {
        let sample = HKQuantitySample(
            type: .init(.heartRate),
            quantity: HKQuantity(unit: .count() / .minute(), doubleValue: 85),
            start: .now,
            end: .now
        )
        let resource = try sample.resource(extensions: MyHeartCountsStandard.defaultHealthObservationFHIRExtensions)
        let observation = try #require(resource.get(if: Observation.self))
        let ext = try #require(observation.extensions(for: FHIRExtensionURL.mhcAppRevision).first)
        func value(ofChild component: String) throws -> ModelsR4.Extension.ValueX {
            let url = FHIRExtensionURL.mhcAppRevision.appending(component: component).r4
            let child = try #require(ext.extension?.first { $0.url == url }, "missing '\(component)' child extension")
            return try #require(child.value)
        }
        guard case .string(let version) = try value(ofChild: "version") else {
            Issue.record("'version' is not a valueString")
            return
        }
        #expect(version.value?.string == MHCAppRevision.version)
        guard case .string(let osVersion) = try value(ofChild: "osVersion") else {
            Issue.record("'osVersion' is not a valueString")
            return
        }
        #expect(osVersion.value?.string == MHCAppRevision.osVersion)
        if let expectedBuild = MHCAppRevision.build {
            guard case .integer(let build) = try value(ofChild: "build") else {
                Issue.record("'build' is not a valueInteger")
                return
            }
            #expect(build.value?.integer == Int32(expectedBuild))
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
    func healthUploadStagingBacklogElision() async throws {
        let healthUploadStaging = HealthUploadStaging(
            persistence: .inMemory,
            autoElideUploadsWhenInsertingDeletions: false
        )
        await withDependencyResolution(standard: FakeStandard()) {
            healthUploadStaging
            HealthKit()
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
        
        try await healthUploadStaging.add(newSamples)
        #expect(try healthUploadStaging.fetchCount(of: HealthUploadStaging.PendingSampleRecord.self) == 2)
        
        let unmatchedDeletionId = UUID()
        try healthUploadStaging.add(
            [
                try HKDeletedObject.make(uuid: newSamples[0].uuid),
                try HKDeletedObject.make(uuid: unmatchedDeletionId)
            ],
            ofType: .stepCount
        )

        let expectedSummary = [SampleType.stepCount.id: 1]
        #expect(try healthUploadStaging.elidePendingUploadsWherePossible(dryRun: true) == expectedSummary)
        #expect(try healthUploadStaging.fetchCount(of: HealthUploadStaging.PendingSampleRecord.self) == 2)
        #expect(try healthUploadStaging.fetchCount(of: HealthUploadStaging.PendingDeletionRecord.self) == 2)

        #expect(try healthUploadStaging.elidePendingUploadsWherePossible(dryRun: false) == expectedSummary)
        #expect(try healthUploadStaging.fetchCount(of: HealthUploadStaging.PendingSampleRecord.self) == 1)
        #expect(try healthUploadStaging.fetchCount(of: HealthUploadStaging.PendingDeletionRecord.self) == 1)
        let deletionChunk = try #require(try healthUploadStaging.fetchNextDrainChunk(
            of: HealthUploadStaging.PendingDeletionRecord.self,
            before: .now,
            limit: 10
        ))
        #expect(deletionChunk.sampleType == SampleType.stepCount.id)
        #expect(deletionChunk.rows.map(\.sampleId) == [unmatchedDeletionId])
    }
    
    
    @Test
    func healthUploadStagingJSONPersistence() async throws { // swiftlint:disable:this function_body_length
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
        let issuedDate = try ModelsR4.FHIRPrimitive<ModelsR4.Instant>(.init(date: timestamp))
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
        var drainedSampleTypes: Set<String> = []
        var allDecodedSamples: Set<ModelsR4.ResourceProxy> = []
        while let chunk = try healthUploadStaging.fetchNextDrainChunk(
            of: HealthUploadStaging.PendingSampleRecord.self,
            before: .now,
            limit: 100
        ) {
            drainedSampleTypes.insert(chunk.sampleType)
            let jsonArray = try chunk.rows.jsonArrayData()
            let resources = try JSONDecoder().decode(Set<ModelsR4.ResourceProxy>.self, from: jsonArray)
            allDecodedSamples.formUnion(resources)
            try healthUploadStaging.remove(chunk)
        }
        #expect(try healthUploadStaging.fetchNextDrainChunk(
            of: HealthUploadStaging.PendingDeletionRecord.self,
            before: .now,
            limit: 100
        ) == nil)
        #expect(drainedSampleTypes == [SampleType.stepCount.id, SampleType.heartRate.id])
        #expect(allDecodedSamples == samplesAsFHIR)
        #expect(try healthUploadStaging.isEmpty)
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
