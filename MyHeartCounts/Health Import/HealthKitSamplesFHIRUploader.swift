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
        try await storeSamples(samples, of: sampleType)
    }

    private func storeSamples<Sample>(_ samples: consuming [Sample], of sampleType: SampleType<Sample>) async throws {
        guard let standard else {
            throw ProcessingError.missingStandard
        }
        let subject = try await standard.firebaseConfiguration.fhirExchangeSubject
        let healthKit = await standard.healthKit
        let conversionInstant = Date.now
        let stateStore = await standard.fhirExchangeStateStore
        var entries: [PreparedHealthObservationFHIRPayload.Entry] = []
        for sample in consume samples {
            try Task.checkCancellation()
            let healthSample = sample as HKSample
            do {
                let payload = try await healthSample.prepareFHIRPayload(
                    conversionInstant: conversionInstant,
                    subject: subject,
                    stateStore: stateStore,
                    using: healthKit
                )
                entries.append(contentsOf: payload.entries)
            } catch {
                await standard.logger.warning(
                    "Failed \(healthSample.sampleType.identifier) \(healthSample.uuid): \(String(describing: error))"
                )
                throw error
            }
        }
        guard !entries.isEmpty else {
            return
        }
        entries.sort(by: healthUploadEntryPrecedes)
        let sourceIDs = entries.map(\.sourceID)
        let eventKeys = entries.compactMap(\.eventKey)
        let resources = entries.map(\.resource)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let encoded = try encoder.encode(resources)
        let compressed = try (consume encoded).compressed(using: Zstd.self)
        let filename = HealthUploadBatchFilename.make(
            typePrefix: sampleType.id,
            identifiers: sourceIDs,
            fileExtension: "json.zstd"
        )
        let compressedUrl = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try (consume compressed).write(to: compressedUrl, options: .atomic)
        defer {
            try? FileManager.default.removeItem(at: compressedUrl)
        }

        // Staging is durable and cancellation-safe; the event ledger is completed only afterwards.
        try await standard.stageHistoricalHealthKitFile(at: compressedUrl)
        do {
            try stateStore.completeHealthKitEvents(eventKeys)
        } catch {
            await standard.logger.error("Could not clean durable HealthKit FHIR event state: \(error)")
        }
    }
}
