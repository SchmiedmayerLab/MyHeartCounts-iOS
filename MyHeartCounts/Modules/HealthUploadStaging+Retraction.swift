//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFHIRContract
import GroveFoundation
import ModelsR4


extension HealthUploadStaging {
    /// The retraction bundles for one drained chunk of deletions.
    ///
    /// Deletions leave as Grove Mobile Retraction Bundles minted from the same identity scope as
    /// the additions they retract. A record whose type never produced an exported graph node has
    /// nothing to retract and is dropped with its row.
    func retractionBatch(
        for rows: some Collection<PendingDeletionRecord>
    ) async throws -> RetractionBatch? {
        let accountDataGeneration = LocalPreferencesStore.standard[.accountDataGeneration]
        try FHIRExchangeDestination.validateWrites(for: accountDataGeneration)
        let subject = try await resolvedSubject()
        let stateStore = resolvedStateStore(accountDataGeneration: accountDataGeneration)
        let recordedAt = Date.now
        try Swift::Task.checkCancellation()
        // One ledger transaction reserves the whole chunk before any retraction uses its identity.
        let retractions = try stateStore.healthKitRetractions(
            of: rows.map { row in
                HealthKitDeletedRecord(
                    sourceTypeIdentifier: row.sampleType,
                    nativeRecordID: row.sampleId,
                    deletedAfter: row.deletedAfter,
                    detectedAt: row.timestamp
                )
            },
            subject: subject,
            recordedAt: recordedAt
        )
        var bundles: [ModelsR4.Bundle] = []
        var identifiers: [UUID] = []
        var eventKeys = Set<String>()
        for (row, retraction) in zip(rows, retractions) {
            guard let retraction else {
                continue
            }
            bundles.append(retraction.graph.bundle)
            identifiers.append(row.sampleId)
            eventKeys.insert(retraction.eventKey)
        }
        guard !bundles.isEmpty else {
            return nil
        }
        return RetractionBatch(
            payload: try HealthUploadBatch.encoder.encode(bundles),
            identifiers: identifiers,
            receipt: HealthKitFHIRReservationReceipt(stateStore: stateStore, eventKeys: eventKeys)
        )
    }
}
