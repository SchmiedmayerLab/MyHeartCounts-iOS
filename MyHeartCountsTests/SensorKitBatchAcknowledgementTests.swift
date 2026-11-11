//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFHIRContract
import GroveSensorKit
@testable import MyHeartCounts
import SensorKit
import Testing


/// How a published SensorKit batch ends: acknowledged, then cleaned; or abandoned when no retry can reproduce it.
@Suite
struct SensorKitBatchAcknowledgementTests {
    private struct AcknowledgementFailure: Error {}
    private struct DiscardFailure: Error {}

    private let harness = SensorKitPublicationHarness(sensor: Sensor.deviceUsage, sequence: 11)
    private let uploads = RecordedSensorKitUploads()

    /// Publishes the one record of the batch through `publication`, as the fetcher does, and acknowledges it with
    /// `acknowledge`.
    private static func publishAndAcknowledge(
        through publication: SensorKitBatchPublication,
        acknowledge: () async throws -> Void
    ) async throws {
        try await publication.publishAndAcknowledge {
            try await DeviceUsageFHIRExchangeTests.upload([DeviceUsageFHIRExchangeTests.report()], publication: publication)
        } acknowledge: {
            try await acknowledge()
        }
    }

    /// Whether the batch's retry state still refuses other bytes at the record's coordinate.
    private static func refusesDrift(_ publication: SensorKitBatchPublication) -> Bool {
        do {
            _ = try publication.sourceRecordID(ordinal: 0, evidence: Data("drifted".utf8))
            return false
        } catch {
            guard case .retryContentChanged? = error as? FHIRExchangeStateError else {
                return false
            }
            return true
        }
    }

    /// The batch's retry state, with the instant its records state, stays while its cursor is acknowledged, and only then
    /// is it dropped.
    @Test
    func acknowledgedBatchDropsItsRetryStateOnlyOnceAcknowledged() async throws {
        let publication = try harness.publication(uploads: uploads)
        let laterInstant = SensorKitPublicationHarness.start.addingTimeInterval(3_600)
        let redelivery = try harness.publication(uploads: uploads, at: laterInstant)
        var instantWhileAcknowledging: Date?
        var refusedDriftWhileAcknowledging = false

        try await Self.publishAndAcknowledge(through: publication) {
            instantWhileAcknowledging = try await redelivery.batchFacts().conversionInstant
            refusedDriftWhileAcknowledging = Self.refusesDrift(publication)
        }

        #expect(instantWhileAcknowledging == SensorKitPublicationHarness.start)
        #expect(refusedDriftWhileAcknowledging)
        #expect(try uploads.graphs.count == 1)
        #expect(try await redelivery.batchFacts().conversionInstant == laterInstant)
        #expect(!Self.refusesDrift(publication))
    }

    /// A batch whose acknowledgement fails keeps its retry state, so its redelivery restates it byte for byte, until that
    /// redelivery is acknowledged.
    @Test
    func failedAcknowledgementKeepsTheBatchForItsRedelivery() async throws {
        let publication = try harness.publication(uploads: uploads)
        await #expect(throws: AcknowledgementFailure.self) {
            try await Self.publishAndAcknowledge(through: publication) {
                throw AcknowledgementFailure()
            }
        }
        #expect(Self.refusesDrift(publication))

        let redelivered = RecordedSensorKitUploads()
        let redelivery = try harness.publication(uploads: redelivered, at: SensorKitPublicationHarness.start.addingTimeInterval(3_600))
        try await Self.publishAndAcknowledge(through: redelivery) {}
        #expect(redelivered.all == uploads.all)
        #expect(try redelivered.records.map(\.version) == uploads.records.map(\.version))
        #expect(!Self.refusesDrift(redelivery))
    }

    /// A relaunch finds the batch's retry state where the earlier launch left it, so a redelivery at a later instant
    /// restates every record version of a batch of several records.
    @Test
    func redeliveryAfterARelaunchRestatesEveryRecordVersion() async throws {
        let reports = [DeviceUsageFHIRExchangeTests.report(), DeviceUsageFHIRExchangeTests.report(textInputSessionIdentifier: "text-session-3")]
        try await DeviceUsageFHIRExchangeTests.upload(reports, publication: harness.publication(uploads: uploads))
        let versions = try uploads.records.map(\.version)
        #expect(versions.count == 2)

        let relaunched = SensorKitPublicationHarness(
            sensor: Sensor.deviceUsage,
            sequence: harness.sequence,
            store: harness.store.testingView(accountDataGeneration: harness.store.accountDataGeneration)
        )
        let redelivered = RecordedSensorKitUploads()
        let redelivery = try relaunched.publication(uploads: redelivered, at: SensorKitPublicationHarness.start.addingTimeInterval(3_600))
        try await DeviceUsageFHIRExchangeTests.upload(reports, publication: redelivery)

        #expect(try redelivered.records.map(\.version) == versions)
        #expect(redelivered.all == uploads.all)
    }

    /// A redelivery across an app or OS update or a new study revision states the facts of the first delivery, so every byte
    /// and the archive's name repeat. The facts go with the batch's retry state: a new delivery states the facts of its time.
    @Test
    func aRedeliveryAcrossAnUpdateRepeatsEveryByte() async throws {
        let reports = [DeviceUsageFHIRExchangeTests.report(), DeviceUsageFHIRExchangeTests.report(textInputSessionIdentifier: "text-session-3")]
        let updated = try MyHeartCounts::ConversionFacts.testing(build: "101", operatingSystem: "27.0", studyRevision: 2)
        let first = try harness.publication(uploads: uploads)
        try await DeviceUsageFHIRExchangeTests.upload(reports, publication: first)
        let firstRecords = try uploads.records

        let redelivered = RecordedSensorKitUploads()
        try await DeviceUsageFHIRExchangeTests.upload(reports, publication: harness.publication(uploads: redelivered, facts: updated))
        #expect(redelivered.all == uploads.all)

        try harness.store.completeSensorBatch(first.batchKey)
        let later = RecordedSensorKitUploads()
        try await DeviceUsageFHIRExchangeTests.upload(reports, publication: harness.publication(uploads: later, facts: updated))
        #expect(later.all.map(\.path) != uploads.all.map(\.path))
        let laterRecords = try later.records
        #expect(laterRecords.map(\.sourceRecord) == firstRecords.map(\.sourceRecord))
        #expect(Set(laterRecords.map(\.version)).isDisjoint(with: firstRecords.map(\.version)))
    }

    /// A device renamed or updated while its batch is pending, or a peripheral on new firmware, changes nothing in a
    /// redelivery: SensorKit restates them with each delivery, and the batch states the devices of its first. The devices go
    /// with the batch's retry state, and they alone tell the next delivery's records from the first's.
    @Test
    func aRedeliveryAcrossADeviceChangeRepeatsEveryByte() async throws {
        let reports = [DeviceUsageFHIRExchangeTests.report(), DeviceUsageFHIRExchangeTests.report(textInputSessionIdentifier: "text-session-3")]
        let first = try harness.publication(uploads: uploads, sourceDevices: [.pinnedPeripheral()])
        try await DeviceUsageFHIRExchangeTests.upload(reports, publication: first)
        let firstRecords = try uploads.records
        func deliveryAfterTheChange(to uploads: RecordedSensorKitUploads) throws -> SensorKitBatchPublication {
            try harness.publication(
                uploads: uploads,
                device: UpdatedSensorKitDevice(),
                sourceDevices: [.pinnedPeripheral(firmwareVersion: "5.2")]
            )
        }

        let redelivered = RecordedSensorKitUploads()
        let redelivery = try deliveryAfterTheChange(to: redelivered)
        #expect(redelivery.batchKey == first.batchKey)
        try await DeviceUsageFHIRExchangeTests.upload(reports, publication: redelivery)
        #expect(redelivered.all == uploads.all)

        try harness.store.completeSensorBatch(first.batchKey)
        let later = RecordedSensorKitUploads()
        try await DeviceUsageFHIRExchangeTests.upload(reports, publication: deliveryAfterTheChange(to: later))
        #expect(later.all.map(\.path) != uploads.all.map(\.path))
        let laterRecords = try later.records
        #expect(laterRecords.map(\.sourceRecord) == firstRecords.map(\.sourceRecord))
        #expect(Set(laterRecords.map(\.version)).isDisjoint(with: firstRecords.map(\.version)))
    }

    /// A batch an earlier build persisted without a conversion instant, facts and devices takes those of its next delivery, and
    /// every delivery after that repeats them.
    @Test
    func batchPersistedWithoutAnInstantTakesOneOnItsNextDelivery() async throws {
        let batchKey = try harness.publication(uploads: uploads).batchKey
        let generation = harness.store.accountDataGeneration
        let store = FHIRExchangeStateStore(testingEncodedState: Data("""
            {
              "schemaVersion": 1,
              "accountDataGeneration": \(generation),
              "sensorRetries": {},
              "sensorBatches": {"\(batchKey)": {"timeZoneIdentifier": "Pacific/Kiritimati"}}
            }
        """.utf8), accountDataGeneration: generation)
        let persisted = SensorKitPublicationHarness(sensor: Sensor.deviceUsage, sequence: harness.sequence, store: store)
        let nextInstant = SensorKitPublicationHarness.start.addingTimeInterval(3_600)

        let nextFacts = try MyHeartCounts::ConversionFacts.testing(build: "101")
        let next = try persisted.publication(uploads: uploads, at: nextInstant, facts: nextFacts)
        let facts = try await next.batchFacts(currentTimeZone: .gmt)
        #expect(facts.timeZone.identifier == "Pacific/Kiritimati")
        #expect(facts.conversionInstant == nextInstant)
        #expect(facts.conversionFacts == nextFacts)
        #expect(facts.devices == .testing())

        let later = try persisted.publication(uploads: uploads, at: nextInstant.addingTimeInterval(3_600), device: UpdatedSensorKitDevice())
        #expect(try await later.batchFacts(currentTimeZone: .gmt) == facts)
    }
}


// MARK: Abandonment

extension SensorKitBatchAcknowledgementTests {
    /// Only a failure no retry can reproduce abandons the sensor's pending batches: first discarded, then their retry
    /// state dropped. Any other failure keeps them for their redelivery.
    @Test
    func onlyFailuresNoRetryReproducesAbandonThePendingBatches() async {
        let unreplayable: [any Error] = [
            FHIRExchangeStateError.retryContentChanged(sourceRecordID: "record"),
            FHIRExchangeStateError.invalidPersistedTimeZone("Mars/Olympus_Mons"),
            SensorKit.QueryAnchorAcknowledgementError.pendingBatchMismatch
        ]
        let replayable: [any Error] = [
            FHIRExchangeStateError.staleAccountGeneration(captured: 1, current: 2),
            FHIRExchangeDestinationError.accountChanged,
            SensorKit.QueryAnchorAcknowledgementError.staleCursor,
            RecordedSensorKitUploads.StageFailure(),
            AcknowledgementFailure()
        ]
        for (errors, abandons) in [(unreplayable, true), (replayable, false)] {
            for error in errors {
                var steps: [String] = []
                let abandoned = await abandonPendingSensorKitBatches(of: Sensor.deviceUsage, after: error) {
                    steps.append("discard")
                } dropRetryState: {
                    steps.append("drop retry state")
                }
                #expect(abandoned == abandons, "\(error)")
                #expect(steps == (abandons ? ["discard", "drop retry state"] : []), "\(error)")
            }
        }
    }

    /// Batches that could not be discarded are still pending, so their retry state stays.
    @Test
    func failedDiscardKeepsTheRetryState() async {
        var droppedRetryState = false
        let abandoned = await abandonPendingSensorKitBatches(
            of: Sensor.deviceUsage,
            after: FHIRExchangeStateError.retryContentChanged(sourceRecordID: "record")
        ) {
            throw DiscardFailure()
        } dropRetryState: {
            droppedRetryState = true
        }
        #expect(!abandoned)
        #expect(!droppedRetryState)
    }

    /// A batch whose first zone no longer resolves fails with the error that abandons it, and abandoning it lets the
    /// next fetch publish the range under the zone current then.
    @Test
    func batchWhoseZoneNoLongerResolvesIsAbandoned() async throws {
        let batchKey = try harness.publication(uploads: uploads).batchKey
        let generation = harness.store.accountDataGeneration
        // As an earlier attempt left the store, on a system that no longer knows the zone it persisted.
        let store = FHIRExchangeStateStore(testingEncodedState: Data("""
            {
              "schemaVersion": 1,
              "accountDataGeneration": \(generation),
              "sensorRetries": {},
              "sensorBatches": {"\(batchKey)": {"timeZoneIdentifier": "Mars/Olympus_Mons"}}
            }
        """.utf8), accountDataGeneration: generation)
        let persisted = SensorKitPublicationHarness(sensor: Sensor.deviceUsage, sequence: harness.sequence, store: store)
        let publication = try persisted.publication(uploads: uploads)

        var failure: (any Error)?
        do {
            try await Self.publishAndAcknowledge(through: publication) {}
        } catch {
            failure = error
        }
        let error = try #require(failure)
        #expect(error as? FHIRExchangeStateError == .invalidPersistedTimeZone("Mars/Olympus_Mons"))
        #expect(uploads.all.isEmpty)

        let subject = try persisted.subject
        let abandoned = await abandonPendingSensorKitBatches(of: Sensor.deviceUsage, after: error) {
            // Grove gives up the pending batch.
        } dropRetryState: {
            try store.abandonSensorBatches(subject: subject, sourceToken: publication.sourceToken)
        }
        #expect(abandoned)
        #expect(try await publication.batchFacts(currentTimeZone: .gmt).timeZone == .gmt)
    }
}
