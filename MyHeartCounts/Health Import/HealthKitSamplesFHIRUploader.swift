//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFoundation
import GroveHealthKit
import GroveHealthKitBulkExport
import GroveHealthKitFHIR


struct HealthKitSamplesFHIRUploader: BatchProcessor {
    typealias Output = Void
    
    enum ProcessingError: Error {
        case missingStandard
    }
    
    let standard: MyHeartCountsStandard?
    
    func process<Sample>(_ samples: consuming [Sample], of sampleType: SampleType<Sample>) async throws {
        guard !samples.isEmpty else {
            return
        }
        if let samples = samples as? [HKClinicalRecord] {
            try await storeSamples(samples)
        } else {
            guard let standard else {
                throw ProcessingError.missingStandard
            }
            let url = try encodeSamples(samples, of: sampleType)
            defer {
                try? FileManager.default.removeItem(at: url)
            }
            try await standard.stageHistoricalHealthKitFile(at: url)
        }
    }
    
    func encodeSamples<Sample>(_ samples: consuming [Sample], of sampleType: SampleType<Sample>) throws -> URL {
        let fileManager = FileManager.default
        let resources = try (consume samples).mapIntoResourceProxies(
            extensions: MyHeartCountsStandard.defaultHealthObservationFHIRExtensions
        )
        let encoded = try JSONEncoder().encode(consume resources)
        
        let compressed = try (consume encoded).compressed(using: Zstd.self)
        let compressedUrl = fileManager.temporaryDirectory.appendingPathComponent("\(sampleType.id)_\(UUID().uuidString).json.zstd")
        try (consume compressed).write(to: compressedUrl)
        return compressedUrl
    }
    
    private func storeSamples(_ samples: consuming [HKClinicalRecord]) async throws {
        guard let standard else {
            throw ProcessingError.missingStandard
        }
        for sample in samples {
            try Task.checkCancellation()
            try await standard.uploadHealthObservation(sample)
        }
    }
}
