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


extension HealthKitFHIRExporter {
    /// The outcome of retracting each of many deleted HealthKit records, in record order.
    ///
    /// Grove re-mints every target from the record's own coordinates, so nothing has to survive the addition for a
    /// deletion to name what it retracts. A record class Grove does not inventory has nothing to retract, and a refusal is
    /// reported as Grove stated it, for the caller to upload.
    func healthKitRetractions(of records: [HealthKitDeletedRecord], recordedAt: Date) async throws -> [Retraction.Outcome] {
        let deletions = records.compactMap(\.deletion)
        guard !deletions.isEmpty else {
            return records.map { _ in .nothingToRetract }
        }
        var outcomes: [UUID: Retraction.Outcome] = [:]
        try await retract(deletions, at: recordedAt) { retraction in
            if case .refused(let reason) = retraction.outcome {
                // Never with the record's HealthKit UUID, which must not propagate into logs.
                let diagnostic = reason.diagnostic
                logger.warning(
                    "Grove refused retracting a \(retraction.deletion.sourceType.rawValue) record: \(diagnostic.code) at \(diagnostic.location)"
                )
            }
            outcomes[retraction.deletion.uuid] = retraction.outcome
        }
        return records.map { outcomes[$0.nativeRecordID] ?? .nothingToRetract }
    }
}
