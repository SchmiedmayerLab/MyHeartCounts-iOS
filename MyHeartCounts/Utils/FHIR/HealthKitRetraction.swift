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


/// The retractions of one drained chunk, and the reservations they hold until the chunk is durable.
struct HealthKitRetractions: Sendable {
    /// The retraction of each record at its index; `nil` where the record's type never produced an
    /// exported graph node or Grove refused the retraction.
    let graphs: [ExchangeGraph?]
    /// The chunk's reservations; complete it once the graphs are staged and the chunk is removed. Completing it
    /// also forgets each deleted record's active reservation.
    let receipt: HealthKitFHIRReservationReceipt
}


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


extension HealthKitFHIRExporter {
    /// The Grove Mobile Retraction Bundles for many deleted HealthKit records, one per record.
    ///
    /// Grove re-mints every target from the record's own coordinates, so nothing has to survive the
    /// addition for a deletion to name what it retracts. The whole chunk is one exporter call, so every
    /// event of the chunk is reserved in one ledger transaction.
    func healthKitRetractions(
        of records: [HealthKitDeletedRecord],
        recordedAt: Date
    ) async throws -> HealthKitRetractions {
        let deletions = records.compactMap(\.deletion)
        guard !deletions.isEmpty else {
            return HealthKitRetractions(graphs: Array(repeating: nil, count: records.count), receipt: HealthKitFHIRReservationReceipt())
        }
        var graphs: [UUID: ExchangeGraph] = [:]
        let receipt = try await retract(deletions, at: recordedAt) { retraction in
            switch retraction.outcome {
            case .graph(let graph):
                graphs[retraction.deletion.uuid] = graph
            case .refused(let reason):
                // Never with the record's HealthKit UUID, which must not propagate into logs.
                let diagnostic = reason.diagnostic
                logger.warning(
                    "Grove refused retracting a \(retraction.deletion.sourceType.rawValue) record: \(diagnostic.code) at \(diagnostic.location)"
                )
            case .nothingToRetract:
                break
            }
        }
        return HealthKitRetractions(
            graphs: records.map { graphs[$0.nativeRecordID] },
            receipt: HealthKitFHIRReservationReceipt(CollectionOfOne(receipt))
        )
    }
}
