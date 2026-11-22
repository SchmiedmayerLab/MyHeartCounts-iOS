//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import ModelsR4


enum FHIRResource {
    case r4(any ModelsR4.Resource) // swiftlint:disable:this identifier_name
    
    init(_ resource: any ModelsR4.Resource) {
        self = .r4(resource)
    }
    
    // periphery:ignore - API
    func get<T: ModelsR4.Resource>(as _: T.Type) -> T? {
        switch self {
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
        }
    }
    
    func hash(into hasher: inout Hasher) {
        switch self {
        case .r4(let resource):
            hasher.combine(0)
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
        case .r4(let resource):
            try container.encode("R4", forKey: .version)
            try container.encode(resource, forKey: .resource)
        }
    }
}
