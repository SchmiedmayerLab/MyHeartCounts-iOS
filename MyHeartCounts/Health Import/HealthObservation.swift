//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import FHIRModelsExtensions
import Foundation
import HealthKit
import ModelsDSTU2
import ModelsR4
import MyHeartCountsShared
import SpeziHealthKit
import SpeziHealthKitFHIR


protocol HealthObservation: Sendable { // might want to rename this (@lukas); the resulting ResourceProxy is not necessarily an Observation...)
    var id: UUID { get }
    var sampleTypeIdentifier: String { get }
    
    func resource(
        withMapping mapping: SampleTypesFHIRMapping,
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
        postprocess: @Sendable (inout FHIRResource) throws -> Void = { _ in }
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
            var resource = FHIRResource(observation)
            try postprocess(&resource)
            return AnyEncodable(resource.encodableUnderlyingResource)
        case let record as HKClinicalRecord:
            guard record.fhirResource != nil else {
                throw NSError(mhcErrorCode: .unspecified, localizedDescription: "Missing FHIR Resource")
            }
            var resource = try await FHIRResource(record, using: healthKit)
            switch resource {
            case .r4(let inner):
                if var inner = inner as? any ModelsR4.DomainResource {
                    inner.addSourceRevisionExtensions(for: record.sourceRevision)
                    resource = .r4(inner)
                }
            case .dstu2(let inner):
                if var inner = inner as? any ModelsDSTU2.DomainResource {
                    inner.addSourceRevisionExtensions(for: record.sourceRevision)
                    resource = .dstu2(inner)
                }
            }
            try postprocess(&resource)
            return AnyEncodable(resource)
        default:
            let resourceProxy = try self.resource(
                withMapping: .default,
                issuedDate: issuedDate,
                extensions: MyHeartCountsStandard.defaultHealthObservationFHIRExtensions
            )
            var resource = FHIRResource(resourceProxy.get())
            try postprocess(&resource)
            return AnyEncodable(resource.encodableUnderlyingResource)
        }
    }
}


extension FHIRResource {
    var encodableUnderlyingResource: any Encodable {
        switch self {
        case .r4(let resource):
            resource
        case .dstu2(let resource):
            resource
        }
    }
}
