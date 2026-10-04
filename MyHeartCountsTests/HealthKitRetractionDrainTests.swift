//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GRDB
import GroveFHIRContract
import GroveFoundation
import GroveHealthKit
import GroveHealthKitFHIR
import HealthKit
@testable import MyHeartCounts
import Testing


/// The deletion drain retracts each staged chunk through one exporter call, and releases the chunk's events only
/// once its payload is staged and its rows are removed.
@Suite
struct HealthKitRetractionDrainTests {
    private struct DrainedChunk {
        let payload: Data
        /// The chunk's retraction reservations when its payload was staged.
        let reservations: Int
    }

    /// Stages deletions of `samples` of `sampleType`, as the anchored query reports them.
    private static func delete<Sample>(_ samples: [HKSample], ofType sampleType: SampleType<Sample>, in staging: HealthUploadStaging) throws {
        try staging.add(samples.map { try HKDeletedObject.make(uuid: $0.uuid) }, ofType: sampleType, deletedAfter: nil)
    }

    /// Drains every staged deletion, returning each chunk's decompressed payload.
    private static func drain(_ staging: HealthUploadStaging) async throws -> [DrainedChunk] {
        let ledger = try staging.ledger
        var chunks: [DrainedChunk] = []
        let finished = try await HealthUploadStagingUploader.drainPendingDeletions(
            from: staging,
            before: .distantFuture,
            maximumChunks: nil
        ) { url in
            chunks.append(DrainedChunk(
                payload: try Data(contentsOf: url).decompressed(using: Zstd.self),
                reservations: try ledger.reservationCount
            ))
        }
        #expect(finished)
        return chunks
    }

    /// M4, M12: each chunk is one retract and one release, and the drain forgets the active reservations the deleted
    /// samples' deliveries left behind.
    @Test
    func drainRetractsEachChunkInOneCallAndForgetsTheDeletedSamples() async throws {
        let staging = try await HealthUploadStaging.resolvedForTesting(autoElideUploadsWhenInsertingDeletions: false)
        let ledger = try staging.ledger
        let steps = (0..<3).map(LedgerHarness.steps)
        let heartRates = (3..<5).map(heartRateSample)
        // Delivered, but released never: the reservations a crash after the anchor commit leaves behind.
        _ = try await staging.add(steps)
        _ = try await staging.add(heartRates)
        _ = try staging.drainStagedSamples()
        #expect(try ledger.reservationCount == 5)
        try Self.delete(steps, ofType: .stepCount, in: staging)
        try Self.delete(heartRates, ofType: .heartRate, in: staging)
        let counter = try ledger.countingTransactions()

        let chunks = try await Self.drain(staging)

        #expect(chunks.count == 2)
        #expect(counter.transactions == 4)
        #expect(try ledger.reservationCount == 0)
        #expect(try staging.fetchCount(of: HealthUploadStaging.PendingDeletionRecord.self) == 0)
    }

    /// M12: a chunk's payload is its retraction graphs' validated bytes, spliced in verbatim.
    @Test
    func drainedPayloadSplicesTheRetractionGraphsJSON() async throws {
        let staging = try await HealthUploadStaging.resolvedForTesting()
        try Self.delete((0..<3).map(LedgerHarness.steps), ofType: .stepCount, in: staging)
        var staged: [Data] = []
        var expected: [Data] = []

        _ = try await HealthUploadStagingUploader.drainPendingDeletions(
            from: staging,
            before: .distantFuture,
            maximumChunks: nil
        ) { url in
            staged.append(try Data(contentsOf: url).decompressed(using: Zstd.self))
            // While the chunk holds its events, the exact retry of its rows reproduces the graphs the drain staged.
            let chunk = try #require(try staging.fetchNextDrainChunk(
                of: HealthUploadStaging.PendingDeletionRecord.self,
                before: .distantFuture,
                limit: 100
            ))
            let rows = chunk.rows.sorted { $0.sampleId.uuidString.lowercased() < $1.sampleId.uuidString.lowercased() }
            let retry = try staging.stateStore.healthKitRetractions(
                of: rows.map { row in
                    HealthKitDeletedRecord(
                        sourceTypeIdentifier: row.sampleType,
                        nativeRecordID: row.sampleId,
                        deletedAfter: row.deletedAfter,
                        detectedAt: row.timestamp
                    )
                },
                subject: try LedgerHarness.subject,
                ledger: try staging.ledger,
                recordedAt: .now
            )
            expected.append(splicedJSONArray(retry.graphs.compactMap { $0?.json }))
            retry.receipt.completeAfterSourceAcknowledgement()
        }

        #expect(staged.count == 1)
        #expect(staged == expected)
        #expect(try staging.ledger.reservationCount == 0)
    }

    /// M7: a chunk whose rows could not be removed after staging its payload releases nothing, so the next drain
    /// retracts it again under the same events, and releases them only once the rows are gone.
    @Test
    func chunkReleasesItsEventsOnlyOnceItsRowsAreRemoved() async throws {
        try await withTemporaryRoot { root in
            let database = root.appending(path: "healthObservations.sqlite3", directoryHint: .notDirectory)
            let staging = try await HealthUploadStaging.resolvedForTesting(persistence: .onDisk(url: database))
            let ledger = try staging.ledger
            try Self.delete((0..<3).map(LedgerHarness.steps), ofType: .stepCount, in: staging)
            // Another connection makes removing the drained rows fail.
            let saboteur = try DatabaseQueue(path: database.path(percentEncoded: false))
            try await saboteur.write { db in
                try db.execute(sql: """
                    CREATE TRIGGER failRemoval BEFORE DELETE ON pendingDeletions
                    BEGIN SELECT RAISE(ABORT, 'removal fails'); END
                    """)
            }

            var failedPayload: Data?
            await #expect(throws: (any Error).self) {
                _ = try await HealthUploadStagingUploader.drainPendingDeletions(
                    from: staging,
                    before: .distantFuture,
                    maximumChunks: nil
                ) { url in
                    #expect(try ledger.reservationCount == 3, "the payload is staged while the chunk holds its events")
                    failedPayload = try Data(contentsOf: url).decompressed(using: Zstd.self)
                }
            }
            #expect(try ledger.reservationCount == 3)
            #expect(try staging.fetchCount(of: HealthUploadStaging.PendingDeletionRecord.self) == 3)

            try await saboteur.write { db in
                try db.execute(sql: "DROP TRIGGER failRemoval")
            }
            let drained = try await Self.drain(staging)
            #expect(drained.map(\.payload) == [try #require(failedPayload)])
            #expect(drained.map(\.reservations) == [3])
            #expect(try ledger.reservationCount == 0)
            try saboteur.close()
        }
    }
}
