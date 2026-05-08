//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import HealthKit
import HealthKitOnFHIR
import ModelsDSTU2
import ModelsR4
import MyHeartCountsShared
import SpeziHealthKit


protocol HealthObservation: Sendable { // might want to rename this (@lukas); the resulting ResourceProxy is not necessarily an Observation...)
    var id: UUID { get }
    var sampleTypeIdentifier: String { get }
    
    func resource(
        withMapping mapping: HKSampleMapping,
        issuedDate: ModelsR4.FHIRPrimitive<ModelsR4.Instant>?,
        extensions: [any FHIRExtensionBuilderProtocol]
    ) throws -> ModelsR4.ResourceProxy
}


extension HKSample: HealthObservation {
    var id: UUID {
        uuid
    }
    
    var sampleTypeIdentifier: String {
        sampleType.identifier
    }
}


extension TimedWalkingTestResult: HealthObservation {
    static let sampleTypeIdentifier = "MHCHealthObservationTimedWalkingTestResultIdentifier"
    
    var sampleTypeIdentifier: String {
        Self.sampleTypeIdentifier
    }
}


// MARK: Utils

extension HealthObservation {
    func turnIntoFHIRResource(
        issuedDate: ModelsR4.FHIRPrimitive<ModelsR4.Instant>,
        using healthKit: HealthKit,
        postprocess: @Sendable (FHIRResource) throws -> Void = { _ in }
    ) async throws -> AnyEncodable {
        switch self {
        case let sample as HKElectrocardiogram:
            let symptoms = try await sample.symptoms(from: healthKit)
            let voltages = try await sample.voltageMeasurements(from: healthKit.healthStore)
            let observation = try sample.observation(
                symptoms: symptoms,
                voltageMeasurements: voltages.map { (time: $0.timeOffset, value: $0.voltage) },
                withMapping: .default,
                issuedDate: issuedDate,
                extensions: MyHeartCountsStandard.defaultHealthObservationFHIRExtensions
            )
            try postprocess(FHIRResource(observation))
            return AnyEncodable(observation)
        case let record as HKClinicalRecord:
            guard record.fhirResource != nil else {
                throw NSError(mhcErrorCode: .unspecified, localizedDescription: "Missing FHIR Resource")
            }
            let resource = try await FHIRResource(record, using: healthKit)
            switch resource {
            case .dstu2(let resource):
                (resource as? ModelsDSTU2.DomainResource)?.addSourceRevisionExtensions(for: record.sourceRevision)
            case .r4(let resource):
                (resource as? ModelsR4.DomainResource)?.addSourceRevisionExtensions(for: record.sourceRevision)
            }
            try postprocess(resource)
            return AnyEncodable(resource)
        default:
            let resource = try self.resource(
                withMapping: .default,
                issuedDate: issuedDate,
                extensions: MyHeartCountsStandard.defaultHealthObservationFHIRExtensions
            )
            try postprocess(FHIRResource(resource.get()))
            return AnyEncodable(resource)
        }
    }
}
