//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import ModelsDSTU2
import ModelsR4


enum FHIRResource {
    case dstu2(any ModelsDSTU2.Resource)
    case r4(any ModelsR4.Resource) // swiftlint:disable:this identifier_name
    
    // periphery:ignore - API
    init(_ resource: any ModelsDSTU2.Resource) {
        self = .dstu2(resource)
    }
    
    init(_ resource: any ModelsR4.Resource) {
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
    
    // periphery:ignore - API
    func get<T: ModelsR4.Resource>(as _: T.Type) -> T? {
        switch self {
        case .dstu2:
            nil
        case .r4(let resource):
            resource as? T
        }
    }
}


extension FHIRResource: Hashable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case let (.r4(lhs), .r4(rhs)):
            lhs.isEqual(rhs)
        case let (.dstu2(lhs), .dstu2(rhs)):
            lhs.isEqual(rhs)
        case (.r4, .dstu2), (.dstu2, .r4):
            false
        }
    }
    
    func hash(into hasher: inout Hasher) {
        switch self {
        case .r4(let resource):
            hasher.combine(0)
            resource.hash(into: &hasher)
        case .dstu2(let resource):
            hasher.combine(1)
            resource.hash(into: &hasher)
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
            let resourceProxy = try container.decode(ModelsDSTU2::ResourceProxy.self, forKey: .resource)
            self = .dstu2(resourceProxy.get())
        case "R4":
            let resourceProxy = try container.decode(ModelsR4::ResourceProxy.self, forKey: .resource)
            self = .r4(resourceProxy.get())
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
