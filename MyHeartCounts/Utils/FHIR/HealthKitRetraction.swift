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
import HealthKit
import ModelsR4


/// One deleted HealthKit record, as the per-type anchored query reported it.
struct HealthKitDeletedRecord: Sendable {
    let sourceTypeIdentifier: String
    let nativeRecordID: UUID
    let deletedAt: Date
}


enum HealthKitRetraction {
    /// One graph node the addition path minted for a record of a given source type.
    struct Output: Hashable, Sendable {
        let role: String
        let discriminator: String
        let resourceType: ResourceType
        let targetRole: RetractionTargetRole
    }

    /// Every output a record of this source type left behind, re-minted from the type alone.
    ///
    /// The addition path routes a record two ways and this answers each from the authority that
    /// minted it: a sample takes the output Grove's converter publishes for its type, while a
    /// clinical record or CDA document is carried byte-for-byte as a `clinical-record`
    /// DocumentReference. An ECG additionally publishes its period average under a fixed child role.
    ///
    /// Empty for a source type this app never exported, so no event is spent naming nothing.
    ///
    /// - Note: A workout's segments are deliberately unnamed. Their discriminator is composed from
    ///   the deleted sample's own event and activity intervals, which HealthKit no longer serves
    ///   once the workout is gone, so they cannot be re-derived the way every identity here is. The
    ///   session's addition bundle published each segment under `Observation.hasMember` and on the
    ///   conversion `Provenance.target`, so a consumer resolves them from the graph it already
    ///   holds once the session is retracted.
    static func outputs(forSourceType identifier: String) -> [Output] {
        if isCarriedAsDocument(identifier) {
            return [
                Output(
                    role: "clinical-record",
                    discriminator: "single",
                    resourceType: .documentReference,
                    targetRole: .sourceArtifact
                )
            ]
        }
        guard let primary = HealthKitCatalog.primaryObservationOutput(
            forSourceTypeIdentifier: identifier
        ) else {
            return []
        }
        var outputs = [
            Output(
                role: primary.role,
                discriminator: primary.discriminator,
                resourceType: .observation,
                targetRole: .primaryOutput
            )
        ]
        if identifier == HKObjectType.electrocardiogramType().identifier {
            // Named unconditionally: whether the deleted sample carried an average heart rate is
            // unknowable once it is gone. Naming an output that was never minted resolves to
            // nothing, where naming none orphans a real one.
            outputs.append(Output(
                role: "average-heart-rate",
                discriminator: "single",
                resourceType: .observation,
                targetRole: .childOutput
            ))
        }
        return outputs
    }

    /// The record classes the addition path carries as documents rather than Observations.
    ///
    /// `HealthObservation.prepareFHIRPayload` routes those on the sample's class; a deletion carries
    /// only its type, so the platform answers the same question by identifier.
    private static func isCarriedAsDocument(_ identifier: String) -> Bool {
        identifier == HKDocumentTypeIdentifier.CDA.rawValue
            || HKObjectType.clinicalType(forIdentifier: HKClinicalTypeIdentifier(rawValue: identifier)) != nil
    }
}


extension FHIRExchangeStateStore {
    /// The Grove Mobile Retraction Bundle for one deleted HealthKit record.
    ///
    /// Every identity re-mints from the record's own coordinates — the adapter, its source type,
    /// the account's repository scope, and the lowercased HealthKit UUID — so nothing has to
    /// survive the addition for a deletion to name what it retracts. Each target additionally
    /// carries the native UUID under the same authorized disclosure the addition path uses, so a
    /// consumer can delete the exact native record.
    ///
    /// - Returns: `nil` when the record's type never produced an exported graph node.
    func healthKitRetraction(
        of record: HealthKitDeletedRecord,
        subject: FHIRExchangeSubject,
        recordedAt: Date
    ) throws -> (eventKey: String, graph: ExchangeGraph)? {
        let outputs = HealthKitRetraction.outputs(forSourceType: record.sourceTypeIdentifier)
        guard !outputs.isEmpty else {
            return nil
        }
        let nativeRecordID = record.nativeRecordID.uuidString.lowercased()
        let eventKey = healthKitRetractionEventKey(
            subject: subject,
            sourceType: record.sourceTypeIdentifier,
            nativeRecordID: record.nativeRecordID
        )
        let event = try event(key: eventKey, recordedAt: recordedAt, facts: .current)
        let scope = try identityScope()
        let repositoryScope = try repositoryScope(.healthKit, subject: subject)
        let eventIdentifier = try eventIdentifier(for: event)
        let producer = try scope.deviceSnapshot(
            eventIdentifier: eventIdentifier,
            deviceRole: .application,
            sourceDeviceToken: event.facts.applicationToken
        )
        let graph = try RetractionEventBuilder.build(
            targets: try retractionTargets(
                outputs,
                of: record,
                scope: scope,
                repositoryScope: repositoryScope
            ),
            context: RetractionEventContext(
                eventIdentifier: eventIdentifier,
                entryNodeIdentifierSystem: FHIRExchangeIdentifiers.entryNode,
                producer: producer.reference(to: .device),
                sourceRecord: scope.sourceRecord(
                    adapterID: "healthkit",
                    sourceType: record.sourceTypeIdentifier,
                    repositoryScope: repositoryScope,
                    nativeRecordID: nativeRecordID
                ),
                sourceRetractionTime: record.deletedAt,
                recordedAt: event.recordedAt
            )
        )
        return (eventKey, graph)
    }

    private func retractionTargets(
        _ outputs: [HealthKitRetraction.Output],
        of record: HealthKitDeletedRecord,
        scope: PseudonymousIdentityScope,
        repositoryScope: BusinessIdentifier
    ) throws -> [RetractionTarget] {
        let nativeRecordID = record.nativeRecordID.uuidString.lowercased()
        let nativeRecordIdentifier = GovernedSourceIdentifierDisclosurePolicy
            .authorized(system: FHIRExchangeIdentifiers.healthKitNativeRecord)
            .identifier(for: nativeRecordID)
        return try outputs.map { output in
            try RetractionTarget(
                identifier: scope.sourceOutput(
                    adapterID: "healthkit",
                    sourceType: record.sourceTypeIdentifier,
                    repositoryScope: repositoryScope,
                    nativeRecordID: nativeRecordID,
                    outputRole: output.role,
                    outputDiscriminator: output.discriminator
                ),
                resourceType: output.resourceType,
                role: output.targetRole,
                nativeRecordIdentifier: nativeRecordIdentifier
            )
        }
    }

    func healthKitRetractionEventKey(
        subject: FHIRExchangeSubject,
        sourceType: String,
        nativeRecordID: UUID
    ) -> String {
        let native = nativeRecordID.uuidString.lowercased()
        return "healthkit-retraction|\(subject.identity.systemValue)|\(subject.identity.value)|\(sourceType)|\(native)"
    }
}
