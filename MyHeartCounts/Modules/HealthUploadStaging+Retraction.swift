//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFoundation
import GroveHealthKitFHIR


extension HealthUploadStaging {
    /// The outcome of retracting each of `rows` under `subject`, in row order, in one exporter call.
    ///
    /// Deletions leave as Grove Mobile Retraction Bundles minted from the same identity scope as the additions they
    /// retract. A record whose type never produced an exported record has nothing to retract.
    ///
    /// - throws: ``FHIRExchangeDestinationError/accountChanged`` when `subject` is no longer the account the exporter was
    ///     built for, a transient error that leaves the chunk for the next drain.
    func retractionBatch(
        for rows: some Collection<PendingDeletionRecord>,
        subject: FHIRExchangeSubject
    ) async throws -> [HealthKitFHIRExporter.Retraction.Outcome] {
        let accountDataGeneration = LocalPreferencesStore.standard[.accountDataGeneration]
        try FHIRExchangeDestination.validateWrites(for: accountDataGeneration)
        let exporter = try await retractionExporter(subject: subject, accountDataGeneration: accountDataGeneration)
        let recordedAt = Date.now
        try Swift::Task.checkCancellation()
        return try await exporter.healthKitRetractions(
            of: rows.map { row in
                HealthKitDeletedRecord(
                    sourceTypeIdentifier: row.sampleType,
                    nativeRecordID: row.sampleId,
                    deletedAfter: row.deletedAfter,
                    detectedAt: row.timestamp
                )
            },
            recordedAt: recordedAt
        )
    }
}
