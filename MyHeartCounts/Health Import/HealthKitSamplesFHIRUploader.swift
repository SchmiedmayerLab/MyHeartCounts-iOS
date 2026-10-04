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
    typealias Output = HealthKitFHIRReservationReceipt

    let standard: MyHeartCountsStandard

    func process<Sample>(
        _ samples: consuming [Sample],
        of sampleType: SampleType<Sample>
    ) async throws -> HealthKitFHIRReservationReceipt {
        guard !samples.isEmpty else {
            return HealthKitFHIRReservationReceipt()
        }
        return try await storeSamples(samples, of: sampleType)
    }

    private func storeSamples<Sample>(
        _ samples: consuming [Sample],
        of sampleType: SampleType<Sample>
    ) async throws -> HealthKitFHIRReservationReceipt {
        let accountDataGeneration = LocalPreferencesStore.standard[.accountDataGeneration]
        try FHIRExchangeDestination.validateWrites(for: accountDataGeneration)
        let subject = try await standard.firebaseConfiguration.fhirExchangeSubject
        let healthKit = await standard.healthKit
        let conversionInstant = Date.now
        let stateStore = await standard.fhirExchangeStateStore(
            accountDataGeneration: accountDataGeneration
        )
        let ledger = await standard.fhirExchangeLedger
        let exporter = try stateStore.healthKitExporter(subject: subject, ledger: ledger)
        var entries: [PreparedHealthObservationFHIRPayload.Entry] = []
        var receipts: [HealthKitFHIRExporter.Receipt] = []
        for sample in consume samples {
            try Task.checkCancellation()
            let healthSample = sample as HKSample
            do {
                let payload = try await healthSample.prepareFHIRPayload(with: exporter, at: conversionInstant, using: healthKit)
                entries.append(contentsOf: payload.entries)
                if let receipt = payload.receipt {
                    receipts.append(receipt)
                }
            } catch {
                await standard.logger.warning(
                    "Failed \(healthSample.sampleType.identifier) \(healthSample.uuid): \(String(describing: error))"
                )
                throw error
            }
        }
        guard !entries.isEmpty else {
            return HealthKitFHIRReservationReceipt(receipts)
        }
        let compressedUrl = try HealthUploadBatch.write(entries, typePrefix: sampleType.id)
        defer {
            try? FileManager.default.removeItem(at: compressedUrl)
        }

        // Staging is durable and cancellation-safe. Grove releases these retry reservations only
        // after it has durably marked the source batch descriptor complete.
        try await standard.stageHistoricalHealthKitFile(
            at: compressedUrl,
            accountDataGeneration: accountDataGeneration
        )
        return HealthKitFHIRReservationReceipt(receipts)
    }

    func didPersist(_ output: HealthKitFHIRReservationReceipt) async {
        output.completeAfterSourceAcknowledgement()
    }
}
