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


extension HealthUploadStaging {
    /// The retraction bundles for one drained chunk of deletions.
    ///
    /// Deletions leave as Grove Mobile Retraction Bundles minted from the same identity scope as
    /// the additions they retract, in one exporter call per chunk. Each graph's validated bytes are
    /// spliced into the payload verbatim. A record whose type never produced an exported graph node
    /// has nothing to retract and is dropped with its row.
    func retractionBatch(
        for rows: some Collection<PendingDeletionRecord>
    ) async throws -> RetractionBatch {
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
            ledger: resolvedLedger(),
            recordedAt: recordedAt
        )
        var graphs: [ExchangeGraph] = []
        var identifiers: [UUID] = []
        for (row, graph) in zip(rows, retractions.graphs) {
            guard let graph else {
                continue
            }
            graphs.append(graph)
            identifiers.append(row.sampleId)
        }
        let payload = HealthUploadBatch.jsonArray(graphs) { graph in
            graph.json
        }
        return RetractionBatch(
            payload: graphs.isEmpty ? nil : payload,
            identifiers: identifiers,
            receipt: retractions.receipt
        )
    }
}
