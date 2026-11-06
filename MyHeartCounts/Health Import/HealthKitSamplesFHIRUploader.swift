//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFHIRContract
import GroveFoundation
import GroveHealthKit
import GroveHealthKitBulkExport
import GroveHealthKitFHIR


/// Exports each bulk batch in as few exporter calls as ``HealthKitFHIRExporter/voltageBudget`` allows, packs its records
/// into one Bundle, and stages it as the batch's upload file.
///
/// A batch past the packer's caps becomes several Bundles, each staged as a file of its own.
///
/// Everything it reaches beyond the samples is injected, so tests run ``process(_:of:)`` themselves, without a signed-in
/// account, Firebase or the app's exporter holder.
struct HealthKitSamplesFHIRUploader: BatchProcessor {
    typealias Output = Void

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

    func process<Sample>(
        _ samples: consuming [Sample],
        of sampleType: SampleType<Sample>
    ) async throws {
        guard !samples.isEmpty else {
            return
        }
        let accountDataGeneration = LocalPreferencesStore.standard[.accountDataGeneration]
        try FHIRExchangeDestination.validateWrites(for: accountDataGeneration)
        let numSamples = samples.count
        let exporter = exporter
        let stage = stage
        do {
            let exporter = try await exporter(accountDataGeneration)
            let samples = samples
            // The logged outcome covers the staging too: a batch counts as exported once its upload file is staged.
            _ = try await HealthKitExportLog.record(.historical, samples: HealthKitExportLog.counts(samples), exporter: exporter) {
                // Potential memory hotspot: this buffers all exchange records for a time window before packing them.
                // If memory pressure becomes an issue, investigate streaming encoding/compression while keeping large upload files.
                let conversionInstant = Date.now
                var records: [ExchangeRecord] = []
                let export = try await exporter.exportBatch(
                    samples,
                    at: conversionInstant,
                    recordProvider: .healthKit(healthKit)
                ) { entry in
                    records.append(try entry.exchangeRecord())
                }
                try await HealthUploadBatch.stage(records, sampleType: sampleType.id, packedAt: conversionInstant) { url in
                    try await stage(url, accountDataGeneration)
                }
                return export
            }
        } catch {
            logger.warning("Failed exporting \(numSamples) \(sampleType.id) samples: \(String(describing: error))")
            throw error
        }
    }
}


extension HealthKitSamplesFHIRUploader {
    /// Creates a ``HealthKitSamplesFHIRUploader`` configured from the app's standard
    ///
    /// The app's: `standard`'s HealthKit, its exporter, and its historical health uploads.
    init(standard: MyHeartCountsStandard) async {
        let exporterHolder = await standard.healthKitExporterHolder
        self.init(
            healthKit: await standard.healthKit
        ) { accountDataGeneration in
            // The app's one HealthKit exporter, shared with live ingestion.
            do {
                return try exporterHolder.healthKitExporter(forBatchOf: accountDataGeneration)
            } catch FHIRExchangeStateError.healthKitExporterUnavailable {
                // A batch that runs before the launch refresh has built the exporter builds it once and retries.
                await standard.refreshHealthKitExporter()
                return try exporterHolder.healthKitExporter(forBatchOf: accountDataGeneration)
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
