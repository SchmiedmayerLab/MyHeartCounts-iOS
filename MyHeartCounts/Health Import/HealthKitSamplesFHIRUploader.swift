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


/// Exports each bulk batch in as few exporter calls as ``HealthKitFHIRExporter/voltageBudget`` allows, stages its
/// upload file, and holds the batch's reservations until the bulk session has durably recorded the batch as processed.
///
/// Everything it reaches beyond the samples is injected, so tests run ``process(_:of:)`` and ``didPersist(_:)``
/// themselves, without a signed-in account, Firebase or the app's ledger.
struct HealthKitSamplesFHIRUploader: BatchProcessor {
    typealias Output = HealthKitFHIRReservationReceipt

    /// The store an ECG's waveform and symptoms are fetched from.
    private let healthKit: HealthKit
    /// Builds the exporter of one batch, fenced to `accountDataGeneration`.
    private let exporter: @Sendable (_ accountDataGeneration: Int) async throws -> HealthKitFHIRExporter
    /// Durably stages one batch's upload file for `accountDataGeneration`; staging is cancellation-safe.
    private let stage: @Sendable (_ file: URL, _ accountDataGeneration: Int) async throws -> Void
    
    init(
        healthKit: HealthKit,
        exporter: @escaping @Sendable (_ accountDataGeneration: Int) async throws -> HealthKitFHIRExporter,
        stage: @escaping @Sendable (_ file: URL, _ accountDataGeneration: Int) async throws -> Void
    ) {
        self.healthKit = healthKit
        self.exporter = exporter
        self.stage = stage
    }

    /// Returns the batch's reservations, which the bulk session releases through ``didPersist(_:)`` only after it has
    /// durably recorded the batch as processed, so an interrupted batch redelivers the same events.
    func process<Sample>(
        _ samples: consuming [Sample],
        of sampleType: SampleType<Sample>
    ) async throws -> HealthKitFHIRReservationReceipt {
        guard !samples.isEmpty else {
            return HealthKitFHIRReservationReceipt()
        }
        let accountDataGeneration = LocalPreferencesStore.standard[.accountDataGeneration]
        try FHIRExchangeDestination.validateWrites(for: accountDataGeneration)
        let numSamples = samples.count
        let exporter = exporter
        do {
            let exporter = try await exporter(accountDataGeneration)
            let samples = samples
            // The logged outcome covers the staging too: a batch counts as exported once its upload file is staged.
            let export = try await HealthKitExportLog.record(.historical, samples: HealthKitExportLog.counts(samples), exporter: exporter) {
                var entries: [PreparedHealthObservationFHIRPayload.Entry] = []
                let export = try await exporter.exportBatch(
                    samples,
                    at: .now,
                    recordProvider: .healthKit(healthKit)
                ) { entry in
                    entries.append(entry)
                }
                guard !entries.isEmpty else {
                    return export
                }
                let url = try HealthUploadBatch.write(entries, typePrefix: sampleType.id)
                defer {
                    try? FileManager.default.removeItem(at: url)
                }
                try await stage(url, accountDataGeneration)
                return export
            }
            return export.receipt
        } catch {
            logger.warning("Failed exporting \(numSamples) \(sampleType.id) samples: \(String(describing: error))")
            throw error
        }
    }

    func didPersist(_ output: HealthKitFHIRReservationReceipt) async {
        output.completeAfterSourceAcknowledgement()
    }
}


extension HealthKitSamplesFHIRUploader {
    /// Creates a ``HealthKitSamplesFHIRUploader`` configured from the app's standard
    ///
    /// The app's: `standard`'s HealthKit, exchange identity and ledger, and its historical health uploads.
    init(standard: MyHeartCountsStandard) async {
        let ledger = await standard.fhirExchangeLedger
        self.init(
            healthKit: await standard.healthKit
        ) { accountDataGeneration in
            // The app's one HealthKit exporter, shared with live ingestion.
            do {
                return try ledger.healthKitExporter(forBatchOf: accountDataGeneration)
            } catch FHIRExchangeStateError.healthKitExporterUnavailable {
                // A batch that runs before the launch refresh has built the exporter builds it once and retries.
                await standard.refreshHealthKitExporter()
                return try ledger.healthKitExporter(forBatchOf: accountDataGeneration)
            }
        } stage: { file, accountDataGeneration in
            try await standard.managedFileUpload.stage(
                file,
                category: .historicalHealthUpload,
                accountDataGeneration: accountDataGeneration
            )
        }
    }
}
