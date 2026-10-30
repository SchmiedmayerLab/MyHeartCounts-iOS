//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

// swiftlint:disable attributes

import Foundation
import GroveHealthKit
import HealthKit


protocol ModernLocalizedError: LocalizedError {
    var errorDescription: LocalizedStringResource? { get }
    var failureReason: LocalizedStringResource? { get }
    var recoverySuggestion: LocalizedStringResource? { get }
    var helpAnchor: LocalizedStringResource? { get }
}

extension ModernLocalizedError {
    @_disfavoredOverload
    var errorDescription: String? {
        (errorDescription as LocalizedStringResource?).map {
            String(localized: $0)
        }
    }
    
    @_disfavoredOverload
    var failureReason: String? {
        (failureReason as LocalizedStringResource?).map {
            String(localized: $0)
        }
    }
    
    @_disfavoredOverload
    var recoverySuggestion: String? {
        (recoverySuggestion as LocalizedStringResource?).map {
            String(localized: $0)
        }
    }
    
    @_disfavoredOverload
    var helpAnchor: String? {
        (helpAnchor as LocalizedStringResource?).map {
            String(localized: $0)
        }
    }
}


extension HealthKit {
    enum SaveSampleError: Error, ModernLocalizedError {
        case missingHealthKitPermissions([any AnySampleType])
        
        var errorDescription: LocalizedStringResource? {
            switch self {
            case .missingHealthKitPermissions:
                "Unable to save"
            }
        }
        
        var failureReason: LocalizedStringResource? {
            switch self {
            case .missingHealthKitPermissions(let sampleTypes):
                let sampleTypes = sampleTypes.map { "- \($0.mhcDisplayTitle)" }.joined(separator: "\n")
                return "You haven't granted My Heart Counts permission to add data to HealthKit for the following data types:\n\(sampleTypes)"
            }
        }
        
        var recoverySuggestion: LocalizedStringResource? {
            switch self {
            case .missingHealthKitPermissions:
                "You can change this in the iOS Settings app, under Privacy & Security → Health → My Heart Counts"
            }
        }
        
        var helpAnchor: LocalizedStringResource? {
            nil
        }
    }
    
    
    func save(_ sample: HKSample) async throws {
        try await save(CollectionOfOne(sample))
    }
    
    func save(_ samples: some Collection<HKSample>) async throws {
        let permissions = samples.reduce(into: DataAccessRequirements()) { reqs, sample in
            reqs.merge(with: .init(readAndWrite: CollectionOfOne(sample.sampleType)))
        }
        try await askForAuthorization(for: permissions)
        do {
            try await self.healthStore.save(Array(samples))
        } catch let error as HKError where error.code == .errorAuthorizationDenied {
            let sampleTypes: [any AnySampleType] = samples.reduce(into: []) { sampleTypes, sample in
                guard let sampleType = sample.sampleType.sampleType else {
                    return
                }
                if !sampleTypes.contains(where: { $0 == sampleType }) {
                    sampleTypes.append(sampleType)
                }
            }
            throw SaveSampleError.missingHealthKitPermissions(sampleTypes)
        } catch {
            throw error
        }
    }
}
