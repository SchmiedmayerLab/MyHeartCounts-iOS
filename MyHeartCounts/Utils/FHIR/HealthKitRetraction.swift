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
        try healthKitRetractions(of: [record], subject: subject, recordedAt: recordedAt)[0]
    }

    /// The Grove Mobile Retraction Bundles for many deleted HealthKit records, one per record.
    ///
    /// Every event is reserved in one ledger transaction and the identity facts are read once, so a
    /// drain chunk costs a constant number of encrypted ledger passes instead of several per record.
    ///
    /// - Returns: The retraction of each record at its index; `nil` where the record's type never
    ///   produced an exported graph node.
    func healthKitRetractions(
        of records: [HealthKitDeletedRecord],
        subject: FHIRExchangeSubject,
        recordedAt: Date
    ) throws -> [(eventKey: String, graph: ExchangeGraph)?] {
        let targets = records.indices.compactMap { index -> (index: Int, sourceType: HealthKitSourceType)? in
            guard let sourceType = HealthKitSourceType(rawValue: records[index].sourceTypeIdentifier),
                  !HealthKitCatalog.outputs(for: sourceType).isEmpty else {
                return nil
            }
            return (index: index, sourceType: sourceType)
        }
        var retractions: [(eventKey: String, graph: ExchangeGraph)?] = Array(repeating: nil, count: records.count)
        guard !targets.isEmpty else {
            return retractions
        }
        let eventKeys = targets.map { target in
            healthKitRetractionEventKey(
                subject: subject,
                sourceType: records[target.index].sourceTypeIdentifier,
                nativeRecordID: records[target.index].nativeRecordID
            )
        }
        let reservations = try events(forKeys: eventKeys, recordedAt: recordedAt, facts: .current())
        let scope = try eventScope(.healthKit, subject: subject, producerInstance: reservations.producerInstance)
        for (target, (eventKey, event)) in zip(targets, zip(eventKeys, reservations.events)) {
            let record = records[target.index]
            let context = HealthKitConversionContext(
                event: try scope.context(
                    for: event,
                    subject: subject,
                    repositoryIDs: [.bundle: RepositoryID(healthKitRecord: record.nativeRecordID)]
                ),
                options: .myHeartCounts
            )
            // A backwards clock adjustment can put the saved query time after detection. Keep the
            // known upper bound without asserting an invalid period that would prevent draining.
            let deletedAfter = record.deletedAfter.flatMap { $0 <= record.detectedAt ? $0 : nil }
            let retraction = try HealthKitConverter().retraction(
                for: HealthKitSourceRecord(uuid: record.nativeRecordID, type: target.sourceType),
                context: context,
                occurred: .period(start: deletedAfter, end: record.detectedAt)
            )
            retractions[target.index] = (eventKey: eventKey, graph: retraction.graph)
        }
        return retractions
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
