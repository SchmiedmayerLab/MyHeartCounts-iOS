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


/// One deleted HealthKit record, as the per-type anchored query reported it.
struct HealthKitDeletedRecord: Sendable {
    let sourceTypeIdentifier: String
    let nativeRecordID: UUID
    /// When the query before the one that reported the deletion was issued, if known.
    let deletedAfter: Date?
    /// When the anchored query reported the deletion; HealthKit never states when it happened.
    let detectedAt: Date
}


extension FHIRExchangeStateStore {
    /// The Grove Mobile Retraction Bundle for one deleted HealthKit record.
    ///
    /// Grove re-mints every target from the record's own coordinates, so nothing has to survive the
    /// addition for a deletion to name what it retracts.
    ///
    /// - Returns: `nil` when the record's type never produced an exported graph node.
    func healthKitRetraction(
        of record: HealthKitDeletedRecord,
        subject: FHIRExchangeSubject,
        recordedAt: Date
    ) throws -> (eventKey: String, graph: ExchangeGraph)? {
        guard let sourceType = HealthKitSourceType(rawValue: record.sourceTypeIdentifier),
              !HealthKitCatalog.outputs(for: sourceType).isEmpty else {
            return nil
        }
        let eventKey = healthKitRetractionEventKey(
            subject: subject,
            sourceType: record.sourceTypeIdentifier,
            nativeRecordID: record.nativeRecordID
        )
        let event = try event(key: eventKey, recordedAt: recordedAt, facts: .current())
        let context = HealthKitConversionContext(
            event: try eventContext(
                for: event,
                subject: subject,
                repository: .healthKit,
                repositoryIDs: [.bundle: RepositoryID(healthKitRecord: record.nativeRecordID)]
            ),
            options: .myHeartCounts
        )
        let retraction = try HealthKitConverter().retraction(
            for: HealthKitSourceRecord(uuid: record.nativeRecordID, type: sourceType),
            context: context,
            retractedAt: record.detectedAt
        )
        return (eventKey, retraction.graph)
    }

    func healthKitRetractionEventKey(
        subject: FHIRExchangeSubject,
        sourceType: String,
        nativeRecordID: UUID
    ) -> String {
        let native = nativeRecordID.uuidString.lowercased()
        return "healthkit-retraction|\(subject.identity.system.rawValue)|\(subject.identity.value)|\(sourceType)|\(native)"
    }
}
