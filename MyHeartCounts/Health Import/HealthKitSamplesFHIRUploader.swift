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

    /// Exports one bulk batch in one exporter call per ``HealthKitFHIRExporter/voltageBudget`` and hands its
    /// upload file to `stage`, returning the batch's reservations.
    ///
    /// The bulk session releases them through ``didPersist(_:)`` only after it has durably recorded the batch
    /// as processed, so an interrupted batch redelivers the same events.
    static func stageBatch(
        _ samples: [HKSample],
        typePrefix: String,
        using healthKit: HealthKit,
        exporter: @Sendable () async throws -> HealthKitFHIRExporter,
        stage: (URL) async throws -> Void
    ) async throws -> HealthKitFHIRReservationReceipt {
        let (url, export) = try await HealthUploadBatch.write(
            HealthObservationBatch(samples),
            typePrefix: typePrefix,
            at: .now,
            using: healthKit,
            exporter: exporter
        )
        guard let url else {
            return export.receipt
        }
        defer {
            try? FileManager.default.removeItem(at: url)
        }
        try await stage(url)
        return export.receipt
    }

    func process<Sample>(
        _ samples: consuming [Sample],
        of sampleType: SampleType<Sample>
    ) async throws -> HealthKitFHIRReservationReceipt {
        guard !samples.isEmpty else {
            return HealthKitFHIRReservationReceipt()
        }
        let accountDataGeneration = LocalPreferencesStore.standard[.accountDataGeneration]
        try FHIRExchangeDestination.validateWrites(for: accountDataGeneration)
        let subject = try await standard.firebaseConfiguration.fhirExchangeSubject
        let stateStore = await standard.fhirExchangeStateStore(accountDataGeneration: accountDataGeneration)
        let ledger = await standard.fhirExchangeLedger
        let standard = standard
        let numSamples = samples.count
        do {
            return try await Self.stageBatch(
                samples.map { $0 as HKSample },
                typePrefix: sampleType.id,
                using: await standard.healthKit
            ) {
                try stateStore.healthKitExporter(subject: subject, ledger: ledger)
            } stage: { url in
                // Staging is durable and cancellation-safe.
                try await standard.stageHistoricalHealthKitFile(at: url, accountDataGeneration: accountDataGeneration)
            }
        } catch {
            await standard.logger.warning("Failed exporting \(numSamples) \(sampleType.id) samples: \(String(describing: error))")
            throw error
        }
    }

    func didPersist(_ output: HealthKitFHIRReservationReceipt) async {
        output.completeAfterSourceAcknowledgement()
    }
}
