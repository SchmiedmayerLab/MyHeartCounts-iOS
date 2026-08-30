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
import GroveHealthKitFHIR
import GroveSensorKit
import GroveSensorKitFHIR
import MyHeartCountsShared


struct SensorKitRecordReservation: Sendable {
    let sourceRecordID: SensorKitSourceRecordID
    let context: SensorKitConversionContext
}


/// Stable publication facts shared by every record in one acknowledged SensorKit batch.
struct SensorKitBatchPublication: Sendable {
    let stream: SensorKitGroveStream
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
        let stream = try SensorKitGroveStream(sensor)
        self.stream = stream
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
            sourceToken: stream.sourceToken,
            deviceProductType: batchInfo.device.productType
        )
    }

    func reserve(recordOrdinal: Int, evidence: Data) throws -> SensorKitRecordReservation {
        // A publication may outlive the fetch task which created it. Fence every state mutation
        // against logout/account cleanup rather than relying only on the initial snapshot.
        try destination.validateCurrentAccount()
        let sourceRecordID = SensorKitSourceRecordID.derived(
            acquisitionBatch: acquisitionBatch,
            sourceToken: stream.sourceToken,
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

    private func reservation(
        for sourceRecordID: SensorKitSourceRecordID
    ) throws -> SensorKitRecordReservation {
        let eventKey = stateStore.sensorKitEventKey(
            batchKey: batchKey,
            sourceRecordID: sourceRecordID
        )
        let application = HealthKitApplication.main
        let host = FHIRExchangeRuntimeFacts.host
        let event = try stateStore.event(
            key: eventKey,
            recordedAt: conversionInstant,
            facts: FHIRExchangeEventFacts(
                applicationToken: application.bundleIdentifier,
                applicationName: application.name,
                applicationVersion: application.version,
                applicationBuild: application.build,
                hostToken: host.sourceDeviceToken,
                hostOperatingSystemVersion: host.operatingSystemVersion,
                hostName: host.name,
                hostManufacturer: host.manufacturer,
                hostModelNumber: host.modelNumber,
                researchStudyIDs: FHIRExchangeIdentifiers.currentResearchStudyIDs()
            )
        )
        return try SensorKitRecordReservation(
            sourceRecordID: sourceRecordID,
            context: SensorKitConversionContext(
                subject: subject.reference,
                subjectIdentity: subject.identity,
                converter: event.sensorApplication,
                converterHost: event.sensorHost,
                eventIdentifier: stateStore.eventIdentifier(for: event),
                entryNodeIdentifierSystem: FHIRExchangeIdentifiers.entryNode,
                identityScope: stateStore.identityScope(),
                repositoryScope: stateStore.repositoryScope(.sensorKit),
                visitLocationIdentifierSystem: FHIRExchangeIdentifiers.visitLocation,
                sourceIdentifierDisclosurePolicy: .authorized(
                    system: FHIRExchangeIdentifiers.sensorKitSourceRecord
                ),
                recordingDevice: nil,
                converterWasGateway: true,
                sourceTimeZone: event.sourceTimeZone,
                recordedAt: event.recordedAt,
                researchStudies: FHIRExchangeIdentifiers.researchStudyReferences(
                    for: event.researchStudyIDs
                )
            )
        )
    }
}


extension MyHeartCountsStandard {
    func sensorKitBatchPublication(
        for sensor: some AnySensor,
        batchInfo: SensorKit.BatchInfo
    ) async throws -> SensorKitBatchPublication {
        let preferences = LocalPreferencesStore.standard
        let accountDataGeneration = preferences[.accountDataGeneration]
        guard !preferences[.pendingAccountDataCleanupRequired] else {
            throw FHIRExchangeDestinationError.accountChanged
        }
        let subject = try await firebaseConfiguration.fhirExchangeSubject
        let destination = FHIRExchangeDestination(
            accountDataGeneration: accountDataGeneration,
            accountID: subject.identity.value
        )
        try destination.validateCurrentAccount()
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
}
