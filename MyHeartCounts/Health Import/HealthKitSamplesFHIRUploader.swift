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
    let healthKit: @Sendable () async -> HealthKit
    /// Builds the exporter of one batch, fenced to `accountDataGeneration`.
    let exporter: @Sendable (_ accountDataGeneration: Int) async throws -> HealthKitFHIRExporter
    /// Durably stages one batch's upload file for `accountDataGeneration`; staging is cancellation-safe.
    let stage: @Sendable (_ file: URL, _ accountDataGeneration: Int) async throws -> Void

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
            var entries: [PreparedHealthObservationFHIRPayload.Entry] = []
            let export = try await exporter(accountDataGeneration).exportBatch(samples, at: .now, using: await healthKit()) { entry in
                entries.append(entry)
            }
            guard !entries.isEmpty else {
                return export.receipt
            }
            let url = try HealthUploadBatch.write(entries, typePrefix: sampleType.id)
            defer {
                try? FileManager.default.removeItem(at: url)
            }
            try await stage(url, accountDataGeneration)
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
    /// The app's: `standard`'s HealthKit, exchange identity and ledger, and its historical health uploads.
    init(standard: MyHeartCountsStandard) {
        self.init {
            await standard.healthKit
        } exporter: { accountDataGeneration in
            let subject = try await standard.firebaseConfiguration.fhirExchangeSubject
            return try await standard.fhirExchangeStateStore(accountDataGeneration: accountDataGeneration)
                .healthKitExporter(subject: subject, ledger: standard.fhirExchangeLedger)
        } stage: { file, accountDataGeneration in
            try await standard.stageHistoricalHealthKitFile(at: file, accountDataGeneration: accountDataGeneration)
        }
    }
}
