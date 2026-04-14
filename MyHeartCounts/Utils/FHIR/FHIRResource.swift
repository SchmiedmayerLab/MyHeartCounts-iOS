//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import HealthKit
import ModelsDSTU2
import ModelsR4
import SpeziFHIR
import SpeziHealthKit
import SpeziHealthKitFHIR


enum FHIRResource: Hashable {
    case dstu2(ModelsDSTU2.Resource)
    case r4(ModelsR4.Resource) // swiftlint:disable:this identifier_name
    
    // periphery:ignore - API
    init(_ resource: ModelsDSTU2.Resource) {
        self = .dstu2(resource)
    }
    
    init(_ resource: ModelsR4.Resource) {
        self = .r4(resource)
    }
    
    // periphery:ignore - API
    func get<T: ModelsDSTU2.Resource>(as _: T.Type) -> T? {
        switch self {
        case .dstu2(let resource):
            resource as? T
        case .r4:
            nil
        }
    }
    
    func get<T: ModelsR4.Resource>(as _: T.Type) -> T? {
        switch self {
        case .dstu2:
            nil
        case .r4(let resource):
            resource as? T
        }
    }
}


extension FHIRResource: Codable {
    private enum CodingKeys: CodingKey {
        case version
        case resource
    }
    
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .version) {
        case "DSTU2":
            self = .dstu2(try container.decode(ModelsDSTU2.Resource.self, forKey: .resource))
        case "R4":
            self = .r4(try container.decode(ModelsR4.Resource.self, forKey: .resource))
        case let version:
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath + [CodingKeys.version],
                debugDescription: "Unsupported version '\(version)'"
            ))
        }
    }
    
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .dstu2(let resource):
            try container.encode("DSTU2", forKey: .version)
            try container.encode(resource, forKey: .resource)
        case .r4(let resource):
            try container.encode("R4", forKey: .version)
            try container.encode(resource, forKey: .resource)
        }
    }
}


// MARK: Utils

extension FHIRResource {
    init(_ other: SpeziFHIR.FHIRResource) {
        switch other.versionedResource {
        case .dstu2(let resource):
            self = .dstu2(resource)
        case .r4(let resource):
            self = .r4(resource)
        }
    }
}


extension SpeziFHIR.FHIRResource {
    // periphery:ignore - API
    init(_ other: FHIRResource) {
        switch other {
        case .dstu2(let resource):
            self.init(versionedResource: .dstu2(resource), displayName: "")
        case .r4(let resource):
            self.init(versionedResource: .r4(resource), displayName: "")
        }
    }
}


extension FHIRResource {
    init(_ record: HKClinicalRecord, using healthKit: HealthKit) async throws {
        fatalError("TODO")
//        try await self.init(SpeziFHIR.FHIRResource.initialize(basedOn: record, using: healthKit, loadHealthKitAttachments: true))
    }
}
