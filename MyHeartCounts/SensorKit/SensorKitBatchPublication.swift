//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

@preconcurrency import FirebaseFirestore
import Foundation
import GroveFHIRContract
import GroveFoundation
import GroveSensorKit
import GroveSensorKitFHIR
import MyHeartCountsShared
import OSLog


/// Where the records of a published SensorKit batch go: each sidecar is staged for upload, then each graph is
/// written to the record's Firestore document.
///
/// Injected, so tests publish a batch without Firebase.
struct SensorKitRecordUploader: Sendable {
    /// Durably stages one sidecar file for upload under `category`, fenced to `accountDataGeneration`.
    let stageSidecar: @Sendable (
        _ file: URL,
        _ category: ManagedFileUpload.Category,
        _ accountDataGeneration: Int
    ) async throws -> Void
    /// Writes one record's graph to the document of `sampleType` named by the record's source-record identifier, in
    /// `destination`'s account.
    let writeGraph: @Sendable (
        _ graph: ExchangeGraph,
        _ sourceRecordID: SensorKitSourceRecordID,
        _ sampleType: String,
        _ destination: FHIRExchangeDestination
    ) async throws -> Void
}


/// Stable publication facts shared by every record in one fetched SensorKit batch.
struct SensorKitBatchPublication: Sendable {
    let sourceToken: String
    let batchKey: String
    let destination: FHIRExchangeDestination
    let info: SensorKit.BatchInfo
    /// Where the batch's records go.
    let uploader: SensorKitRecordUploader
    /// When the batch's new events are reserved; a redelivery before the batch is acknowledged restates the first.
    let conversionInstant: Date

    private let acquisitionBatch: SensorKit.AcquisitionBatchCoordinate
    private let deviceProductType: String
    private let subject: FHIRExchangeSubject
    private let stateStore: FHIRExchangeStateStore
    private let ledger: FHIRExchangeLedger

    init(
        sensor: some AnySensor,
        batchInfo: SensorKit.BatchInfo,
        subject: FHIRExchangeSubject,
        destination: FHIRExchangeDestination,
        stateStore: FHIRExchangeStateStore,
        ledger: FHIRExchangeLedger,
        uploader: SensorKitRecordUploader,
        conversionInstant: Date = .now
    ) throws {
        guard let sourceToken = SensorKitCatalog.current.entry(for: sensor)?.sourceToken else {
            throw SensorKitRecordError.sourceTypeNotAdmitted(sensor.id)
        }
        self.sourceToken = sourceToken
        self.destination = destination
        self.info = batchInfo
        self.uploader = uploader
        self.conversionInstant = conversionInstant
        self.acquisitionBatch = batchInfo.acquisitionBatch
        self.deviceProductType = batchInfo.device.productType
        self.subject = subject
        self.stateStore = stateStore
        self.ledger = ledger
        self.batchKey = stateStore.sensorKitBatchKey(
            subject: subject,
            acquisitionBatch: batchInfo.acquisitionBatch,
            sourceToken: sourceToken,
            deviceProductType: batchInfo.device.productType
        )
    }

    /// The identity of the record at `ordinal` of the batch, once `evidence`, and `supplementalEvidence` if given,
    /// are checked against the bytes first seen there.
    ///
    /// - throws: `FHIRExchangeStateError.retryContentChanged` when the record's bytes differ from those first seen at
    ///     its acquisition coordinate: the batch can then never be acknowledged as it was first delivered.
    func sourceRecordID(ordinal: Int, evidence: Data, supplementalEvidence: Data? = nil) throws -> SensorKitSourceRecordID {
        // A publication may outlive the fetch task which created it. Fence every state mutation
        // against logout/account cleanup rather than relying only on the initial snapshot.
        try destination.validateCurrentAccount()
        let sourceRecordID = derivedSourceRecordID(ordinal: ordinal)
        try stateStore.verifySensorRetryDigest(evidence, batchKey: batchKey, sourceRecordID: sourceRecordID)
        if let supplementalEvidence {
            try stateStore.verifySensorRetryDigest(
                supplementalEvidence,
                batchKey: batchKey,
                sourceRecordID: sourceRecordID,
                supplement: true
            )
        }
        return sourceRecordID
    }

    /// Checks that no earlier attempt prepared the record at `ordinal`, whose preparation Grove just refused.
    ///
    /// - throws: `FHIRExchangeStateError.retryContentChanged` when an earlier attempt recorded the record's bytes: the
    ///     record it prepared, and may have exported, can then never be reproduced, so the batch fails as on any drift.
    func verifyRefusal(ofRecord ordinal: Int) throws {
        try destination.validateCurrentAccount()
        try stateStore.verifySensorRecordWasNeverPrepared(batchKey: batchKey, sourceRecordID: derivedSourceRecordID(ordinal: ordinal))
    }

    private func derivedSourceRecordID(ordinal: Int) -> SensorKitSourceRecordID {
        SensorKitSourceRecordID.derived(
            acquisitionBatch: acquisitionBatch,
            sourceToken: sourceToken,
            deviceProductType: deviceProductType,
            recordOrdinal: UInt64(ordinal)
        )
    }

    /// The zone the batch states its bounds in: `current` when the batch is first published, and the same zone on
    /// every redelivery, as it is persisted with the batch's retry state.
    func sourceTimeZone(current: TimeZone = .current) throws -> TimeZone {
        try destination.validateCurrentAccount()
        return try stateStore.sensorBatchTimeZone(batchKey, current: current)
    }

    /// The exporter of the batch's records, under the facts as they stand now.
    ///
    /// Building it reads the identity secret and the app facts; it opens no ledger.
    func exporter() throws -> SensorKitFHIRExporter {
        try stateStore.sensorKitExporter(subject: subject, ledger: ledger)
    }

    /// Publishes the batch through `upload` and acknowledges its cursor through `acknowledge`, as one step.
    ///
    /// In order:
    /// 1. `upload` publishes the batch's records. A failure leaves the batch pending.
    /// 2. `acknowledge` makes the batch's cursor durable. Until it succeeds, the batch's events stay reserved and its
    ///    retry state stays, so a redelivery restates the batch byte for byte and still fails closed on drift.
    /// 3. The upload's receipt is released, so a later delivery of the same records is a new event.
    /// 4. The batch's retry state is dropped. A failure is only logged: the cursor is already durable, and a transient
    ///    cleanup failure must not make the acknowledged batch look unpublished or trigger a false retry.
    ///
    /// A process that ends between 2 and 3 leaves the batch's reservations in the ledger until its next reset: their
    /// keys are never fetched again, and Grove offers no call to forget them by key.
    func publishAndAcknowledge(
        upload: () async throws -> ExchangeProducer.Receipt?,
        acknowledge: () async throws -> Void
    ) async throws {
        let receipt = try await upload()
        try await acknowledge()
        receipt?.release()
        do {
            try stateStore.completeSensorBatch(batchKey)
        } catch {
            logger.error("Could not clean acknowledged SensorKit FHIR state: \(error)")
        }
    }
}


extension SensorKitRecordUploader {
    /// The app's: sidecars go to the managed file upload, graphs to the participant's health observations.
    static func managed(by managedFileUpload: ManagedFileUpload) -> Self {
        Self { file, category, accountDataGeneration in
            try await managedFileUpload.stage(file, category: category, accountDataGeneration: accountDataGeneration)
        } writeGraph: { graph, sourceRecordID, sampleType, destination in
            let document = try MyHeartCountsStandard.healthObservationDocument(
                forSampleType: sampleType,
                id: sourceRecordID.value,
                destination: destination
            )
            try await document.setData(try Firestore.Encoder().encode(graph.bundle))
        }
    }
}


extension MyHeartCountsStandard {
    func sensorKitBatchPublication(
        for sensor: some AnySensor,
        batchInfo: SensorKit.BatchInfo
    ) async throws -> SensorKitBatchPublication {
        let accountDataGeneration = LocalPreferencesStore.standard[.accountDataGeneration]
        let subject = try await firebaseConfiguration.fhirExchangeSubject
        let destination = try FHIRExchangeDestination.capture(
            accountID: subject.identity.value,
            accountDataGeneration: accountDataGeneration
        )
        return try SensorKitBatchPublication(
            sensor: sensor,
            batchInfo: batchInfo,
            subject: subject,
            destination: destination,
            stateStore: fhirExchangeStateStore(accountDataGeneration: accountDataGeneration),
            ledger: fhirExchangeLedger,
            uploader: .managed(by: managedFileUpload)
        )
    }

    /// Drops the retry-only state of every batch of `sensor` once Grove abandoned its pending batches.
    ///
    /// The abandoned range is fetched again under fresh acquisition coordinates, so none of those
    /// batches can ever be retried. The key of an abandoned batch is unknown at this point (Grove
    /// refuses to deliver it again), hence the state of all of the sensor's batches is dropped.
    ///
    /// The events an abandoned batch reserved in the exchange ledger stay there: they are keyed by source
    /// records that are never fetched again, so they cost only storage until the ledger is next reset.
    /// Reservations are never forgotten by age, as age alone does not tell an abandoned batch from one
    /// still awaiting its redelivery.
    func abandonSensorKitBatches(for sensor: some AnySensor) async throws {
        guard let sourceToken = SensorKitCatalog.current.entry(for: sensor)?.sourceToken else {
            throw SensorKitRecordError.sourceTypeNotAdmitted(sensor.id)
        }
        let subject = try await firebaseConfiguration.fhirExchangeSubject
        try fhirExchangeStateStore(
            accountDataGeneration: LocalPreferencesStore.standard[.accountDataGeneration]
        ).abandonSensorBatches(subject: subject, sourceToken: sourceToken)
    }
}


/// Whether `error` means that a sensor's pending batch can never be acknowledged, because a retry no longer reproduces it:
/// either SensorKit no longer returns the batch's exact delivery boundary, a record's bytes changed at its reserved coordinate,
/// or the zone the batch was first published in no longer resolves.
private func cannotReplayPendingBatch(after error: any Error) -> Bool {
    if let error = error as? SensorKit.QueryAnchorAcknowledgementError {
        return error == .pendingBatchMismatch
    }
    switch error as? FHIRExchangeStateError {
    case .retryContentChanged, .invalidPersistedTimeZone:
        return true
    default:
        return false
    }
}


/// Abandons the pending batches of `sensor` if `error` means a retry can no longer reproduce them: `discard` makes
/// Grove give them up, then `dropRetryState` removes their retry-only state.
///
/// The next fetch reads an abandoned range again under fresh acquisition coordinates. Records already published from an abandoned
/// batch stay published, so up to one batch may be uploaded twice; that is preferable to the sensor never advancing again.
/// The retry state stays when `discard` fails, as the batches are then still pending.
///
/// - returns: Whether the batches were abandoned.
@discardableResult
func abandonPendingSensorKitBatches(
    of sensor: some AnySensor,
    after error: any Error,
    discard: () async throws -> Void,
    dropRetryState: () async throws -> Void
) async -> Bool {
    guard cannotReplayPendingBatch(after: error) else {
        return false
    }
    do {
        try await discard()
    } catch {
        logger.error("Failed to discard the pending batches of SensorKit sensor '\(sensor.id)': \(error)")
        return false
    }
    do {
        try await dropRetryState()
    } catch {
        // Only retry-only state is left behind, which the next account cleanup removes.
        logger.error("Could not clean abandoned SensorKit FHIR state: \(error)")
    }
    return true
}
