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
import GroveSensorKit
import GroveSensorKitFHIR
import MyHeartCountsShared


struct SensorKitRecordReservation: Sendable {
    let sourceRecordID: SensorKitSourceRecordID
    let context: SensorKitConversionContext
}


/// Stable publication facts shared by every record in one fetched SensorKit batch.
struct SensorKitBatchPublication: Sendable {
    let sourceToken: String
    let batchKey: String
    let destination: FHIRExchangeDestination
    let info: SensorKit.BatchInfo

    private let acquisitionBatch: SensorKit.AcquisitionBatchCoordinate
    private let deviceProductType: String
    private let subject: FHIRExchangeSubject
    private let stateStore: FHIRExchangeStateStore
    private let conversionInstant: Date

    init(
        sensor: some AnySensor,
        batchInfo: SensorKit.BatchInfo,
        subject: FHIRExchangeSubject,
        destination: FHIRExchangeDestination,
        stateStore: FHIRExchangeStateStore,
        conversionInstant: Date = .now
    ) throws {
        guard let sourceToken = SensorKitCatalog.current.entry(for: sensor)?.sourceToken else {
            throw SensorKitRecordError.sourceTypeNotAdmitted(sensor.id)
        }
        self.sourceToken = sourceToken
        self.destination = destination
        self.info = batchInfo
        self.acquisitionBatch = batchInfo.acquisitionBatch
        self.deviceProductType = batchInfo.device.productType
        self.subject = subject
        self.stateStore = stateStore
        self.conversionInstant = conversionInstant
        self.batchKey = stateStore.sensorKitBatchKey(
            subject: subject,
            acquisitionBatch: batchInfo.acquisitionBatch,
            sourceToken: sourceToken,
            deviceProductType: batchInfo.device.productType
        )
    }

    func reserve(recordOrdinal: Int, evidence: Data) throws -> SensorKitRecordReservation {
        // A publication may outlive the fetch task which created it. Fence every state mutation
        // against logout/account cleanup rather than relying only on the initial snapshot.
        try destination.validateCurrentAccount()
        let sourceRecordID = SensorKitSourceRecordID.derived(
            acquisitionBatch: acquisitionBatch,
            sourceToken: sourceToken,
            deviceProductType: deviceProductType,
            recordOrdinal: UInt64(recordOrdinal)
        )
        try stateStore.verifySensorRetryDigest(
            evidence,
            batchKey: batchKey,
            sourceRecordID: sourceRecordID
        )
        return try reservation(for: sourceRecordID)
    }

    /// Releases the event reserved for a record Grove refused; nothing was staged or written for it.
    ///
    /// Best-effort and idempotent, like HealthKit refusals: completing the acknowledged batch removes it anyway.
    func release(_ reservation: SensorKitRecordReservation) {
        try? stateStore.completeExchangeEvents([
            stateStore.sensorKitEventKey(batchKey: batchKey, sourceRecordID: reservation.sourceRecordID)
        ])
    }

    private func reservation(
        for sourceRecordID: SensorKitSourceRecordID
    ) throws -> SensorKitRecordReservation {
        let eventKey = stateStore.sensorKitEventKey(
            batchKey: batchKey,
            sourceRecordID: sourceRecordID
        )
        let event = try stateStore.event(key: eventKey, recordedAt: conversionInstant, facts: .current())
        return SensorKitRecordReservation(
            sourceRecordID: sourceRecordID,
            context: SensorKitConversionContext(
                event: try stateStore.eventContext(for: event, subject: subject, repository: .sensorKit),
                visitLocationIdentifierSystem: FHIRExchangeIdentifiers.visitLocation,
                sourceIdentifierDisclosurePolicy: .authorized(
                    system: FHIRExchangeIdentifiers.sensorKitSourceRecord
                ),
                sourceTimeZone: try event.sourceTimeZone
            )
        )
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
            stateStore: fhirExchangeStateStore(accountDataGeneration: accountDataGeneration)
        )
    }

    func completeSensorKitBatch(_ batchKey: String, accountDataGeneration: Int) throws {
        try fhirExchangeStateStore(
            accountDataGeneration: accountDataGeneration
        ).completeSensorBatch(batchKey)
    }

    /// Drops the retry-only state of every batch of `sensor` once Grove abandoned its pending batches.
    ///
    /// The abandoned range is fetched again under fresh acquisition coordinates, so none of those
    /// batches can ever be retried. The key of an abandoned batch is unknown at this point (Grove
    /// refuses to deliver it again), hence the state of all of the sensor's batches is dropped.
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
