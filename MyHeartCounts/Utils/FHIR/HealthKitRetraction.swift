//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFHIRContract
import GroveHealthKitFHIR
import OSLog


/// One deleted HealthKit record, as the per-type anchored query reported it.
struct HealthKitDeletedRecord: Sendable {
    let sourceTypeIdentifier: String
    let nativeRecordID: UUID
    /// When the query before the one that reported the deletion was issued, if known.
    let deletedAfter: Date?
    /// When the anchored query reported the deletion; HealthKit never states when it happened.
    let detectedAt: Date

    /// The exporter's view of the record; `nil` for a record class Grove does not inventory.
    var deletion: HealthKitFHIRExporter.Deletion? {
        guard let sourceType = HealthKitSourceType(rawValue: sourceTypeIdentifier) else {
            return nil
        }
        return HealthKitFHIRExporter.Deletion(
            uuid: nativeRecordID,
            sourceType: sourceType,
            deletedAfter: deletedAfter,
            detectedAt: detectedAt
        )
    }
}


/// The retractions of one drained chunk, and the reservations they hold until the chunk is durable.
struct HealthKitRetractions: Sendable {
    /// The retraction of each record at its index; `nil` where the record's type never produced an
    /// exported graph node or Grove refused the retraction.
    let graphs: [ExchangeGraph?]
    let receipt: HealthKitFHIRExporter.Receipt?
}


extension FHIRExchangeStateStore {
    /// The Grove Mobile Retraction Bundle for one deleted HealthKit record.
    ///
    /// - Returns: `nil` when the record's type never produced an exported graph node.
    func healthKitRetraction(
        of record: HealthKitDeletedRecord,
        subject: FHIRExchangeSubject,
        ledger: FHIRExchangeLedger,
        recordedAt: Date
    ) throws -> ExchangeGraph? {
        try healthKitRetractions(of: [record], subject: subject, ledger: ledger, recordedAt: recordedAt).graphs[0]
    }

    /// The Grove Mobile Retraction Bundles for many deleted HealthKit records, one per record.
    ///
    /// Grove re-mints every target from the record's own coordinates, so nothing has to survive the
    /// addition for a deletion to name what it retracts. Every event of the chunk is reserved in
    /// one ledger transaction.
    func healthKitRetractions(
        of records: [HealthKitDeletedRecord],
        subject: FHIRExchangeSubject,
        ledger: FHIRExchangeLedger,
        recordedAt: Date
    ) throws -> HealthKitRetractions {
        let deletions = records.compactMap(\.deletion)
        guard !deletions.isEmpty else {
            return HealthKitRetractions(graphs: Array(repeating: nil, count: records.count), receipt: nil)
        }
        var graphs: [UUID: ExchangeGraph] = [:]
        let receipt = try healthKitExporter(subject: subject, ledger: ledger).retract(deletions, at: recordedAt) { export in
            switch export.outcome {
            case .graph(let graph):
                graphs[export.source.uuid] = graph
            case .refused(let reason):
                let diagnostic = reason.diagnostic
                logger.warning(
                    "Grove refused retracting \(export.source.typeIdentifier) \(export.source.uuid): \(diagnostic.code) at \(diagnostic.location)"
                )
            case .nothingToRetract:
                break
            }
        }
        return HealthKitRetractions(graphs: records.map { graphs[$0.nativeRecordID] }, receipt: receipt)
    }
}
