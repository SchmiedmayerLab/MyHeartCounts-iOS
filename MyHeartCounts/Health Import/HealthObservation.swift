//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import FHIRModelsExtensions
import Foundation
import GroveHealthKit
import GroveHealthKitFHIR
import HealthKit
import ModelsDSTU2
import ModelsR4
import MyHeartCountsShared


// swiftlint:disable:next file_types_order
protocol HealthObservation: Sendable { // might want to rename this (@lukas); the resulting ResourceProxy is not necessarily an Observation...)
    var id: UUID { get }
    var sampleTypeIdentifier: String { get }
}


/// A health observation whose FHIR representation My Heart Counts builds itself.
///
/// Covers only what no Grove adapter models: the app's own active-task results and the SensorKit
/// streams Grove admits as raw recordings.
protocol SelfModelledHealthObservation: HealthObservation {
    func resource(
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


extension TimedWalkingTestResult: SelfModelledHealthObservation {
    static let sampleTypeIdentifier = "MHCHealthObservationTimedWalkingTestResultIdentifier"
    
    var sampleTypeIdentifier: String {
        Self.sampleTypeIdentifier
    }
}


// MARK: Utils

extension HealthObservation {
    /// Produces the FHIR payload persisted for this observation.
    ///
    /// A HealthKit sample converts through the Grove HealthKit adapter, which yields a transaction
    /// Bundle holding the Observation, the recording and converting Devices, and the conversion
    /// Provenance. Clinical records already are FHIR and are passed through. Everything else is
    /// modelled by the app itself.
    func turnIntoFHIRResource(
        conversionInstant: Date,
        subject: ModelsR4.Reference,
        using healthKit: HealthKit,
        postprocess: @Sendable (inout FHIRResource) throws -> Void = { _ in }
    ) async throws -> AnyEncodable {
        var resource: FHIRResource
        switch self {
        case let record as HKClinicalRecord:
            resource = try FHIRResource(record)
            switch resource {
            case .r4(let inner):
                if var inner = inner as? any ModelsR4.DomainResource {
                    inner.addSourceRevisionExtensions(for: record.sourceRevision)
                    inner.addMHCAppRevision()
                    resource = .r4(inner)
                }
            case .dstu2(let inner):
                if var inner = inner as? any ModelsDSTU2.DomainResource {
                    inner.addSourceRevisionExtensions(for: record.sourceRevision)
                    inner.addMHCAppRevision()
                    resource = .dstu2(inner)
                }
            }
            try postprocess(&resource)
            return AnyEncodable(resource)
        case let sample as HKSample:
            let conversion = try await HealthKitConverter().convert(
                sample,
                using: healthKit,
                context: .mhc(subject: subject, conversionInstant: conversionInstant)
            )
            resource = FHIRResource(conversion.bundle)
        case let observation as any SelfModelledHealthObservation:
            let resourceProxy = try observation.resource(
                issuedDate: FHIRPrimitive<ModelsR4.Instant>(try .init(date: conversionInstant)),
                extensions: MyHeartCountsStandard.defaultHealthObservationFHIRExtensions
            )
            resource = FHIRResource(resourceProxy.get())
        default:
            throw NSError(
                mhcErrorCode: .unspecified,
                localizedDescription: "No FHIR representation for '\(sampleTypeIdentifier)'"
            )
        }
        try postprocess(&resource)
        return AnyEncodable(resource.encodableUnderlyingResource)
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
