//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveSensorKit
@testable import MyHeartCounts
import SensorKit
import Testing


/// How a published SensorKit batch ends: acknowledged, then released, then cleaned; or abandoned when no retry can
/// reproduce it.
///
/// Serialized: every test publishes the same record, whose batch file is staged under a name its identity derives.
@Suite(.serialized)
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

    /// The batch's events stay reserved and its retry state stays while its cursor is acknowledged; then its events
    /// are released, and only then is its retry state dropped.
    @Test
    func acknowledgedBatchReleasesItsEventsThenDropsItsRetryState() async throws {
        let publication = try harness.publication(uploads: uploads)
        var reservationsWhileAcknowledging: Int?
        var refusedDriftWhileAcknowledging = false

        try await Self.publishAndAcknowledge(through: publication) {
            reservationsWhileAcknowledging = try harness.ledger.reservationCount
            refusedDriftWhileAcknowledging = Self.refusesDrift(publication)
        }

        #expect(reservationsWhileAcknowledging == 1)
        #expect(refusedDriftWhileAcknowledging)
        #expect(try uploads.graphs.count == 1)
        #expect(try harness.ledger.reservationCount == 0)
        #expect(!Self.refusesDrift(publication))
    }

    /// A batch whose acknowledgement fails keeps its events and its retry state, so its redelivery restates it byte
    /// for byte.
    @Test
    func failedAcknowledgementKeepsTheBatchForItsRedelivery() async throws {
        let publication = try harness.publication(uploads: uploads)
        await #expect(throws: AcknowledgementFailure.self) {
            try await Self.publishAndAcknowledge(through: publication) {
                throw AcknowledgementFailure()
            }
        }
        #expect(try harness.ledger.reservationCount == 1)
        #expect(Self.refusesDrift(publication))

        let redelivered = RecordedSensorKitUploads()
        let redelivery = try harness.publication(uploads: redelivered, at: SensorKitPublicationHarness.start.addingTimeInterval(3_600))
        try await Self.publishAndAcknowledge(through: redelivery) {}
        #expect(redelivered.all == uploads.all)
        #expect(try harness.ledger.reservationCount == 0)
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
        #expect(try publication.sourceTimeZone(current: .gmt) == .gmt)
    }
}
