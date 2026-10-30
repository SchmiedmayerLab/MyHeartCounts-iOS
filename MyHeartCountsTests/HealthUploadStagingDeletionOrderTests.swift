//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GRDB
import GroveFoundation
import GroveHealthKit
import HealthKit
@testable import MyHeartCounts
import Synchronization
import Testing


@Suite
struct HealthUploadStagingDeletionOrderTests {
    private static func drainRetraction(_ staging: HealthUploadStaging) async throws {
        var retractions = 0
        _ = try await HealthUploadStagingUploader.drainPendingDeletions(
            from: staging, before: .distantFuture, maximumChunks: nil
        ) { _ in
            retractions += 1
        }
        #expect(retractions == 1)
        #expect(try staging.isEmpty)
        #expect(try staging.ledger.reservationCount == 0)
    }

    @Test
    func deletionDuringStagingWaitsForTheAddition() async throws {
        let staging = try await HealthUploadStaging.resolvedForTesting()
        let sample = LedgerHarness.steps(0)
        let receipt = try await staging.add([sample])
        receipt.completeAfterSourceAcknowledgement()
        let additions = Mutex(0)

        _ = try await HealthUploadStagingUploader.drainPendingSamples(
            from: staging, before: .distantFuture, maximumChunks: nil
        ) { _ in
            try staging.add([try HKDeletedObject.make(uuid: sample.uuid)], ofType: .stepCount, deletedAfter: nil)
            #expect(try staging.fetchCount(of: HealthUploadStaging.PendingSampleRecord.self) == 1)
            #expect(try staging.fetchCount(of: HealthUploadStaging.PendingDeletionRecord.self) == 1)
            #expect(try staging.elidePendingUploadsWherePossible(dryRun: true).isEmpty)
            #expect(try staging.elidePendingUploadsWherePossible().isEmpty)
            // A concurrent or limited drain must not release the retraction while its addition is still being staged.
            _ = try await HealthUploadStagingUploader.drainPendingDeletions(
                from: staging, before: .distantFuture, maximumChunks: nil
            ) { _ in
                Issue.record("The deletion overtook its addition")
            }
            additions.withLock { $0 += 1 }
        }

        #expect(additions.withLock { $0 } == 1)
        #expect(try staging.fetchCount(of: HealthUploadStaging.PendingSampleRecord.self) == 0)
        #expect(try staging.fetchCount(of: HealthUploadStaging.PendingDeletionRecord.self) == 1)
        try await Self.drainRetraction(staging)
    }

    @Test(arguments: [false, true])
    func interruptedStagingRetainsTheDeletionAcrossReopening(failAfterStaging: Bool) async throws {
        try await withTemporaryRoot { root in
            try await checkInterruptedStaging(failAfterStaging: failAfterStaging, at: root)
        }
    }

    @Test
    func redeliveryPreservesAnExistingClaim() async throws {
        let staging = try await HealthUploadStaging.resolvedForTesting()
        let sample = LedgerHarness.steps(0)
        _ = try await staging.add([sample])
        let first = try #require(try staging.claimNextSampleDrainChunk(before: .distantFuture, limit: 1))
        _ = try await staging.add([sample])
        try staging.add([try HKDeletedObject.make(uuid: sample.uuid)], ofType: .stepCount, deletedAfter: nil)
        let retry = try #require(try staging.claimNextSampleDrainChunk(before: .distantFuture, limit: 1))

        #expect(retry.rows.map(\.fhirJson) == first.rows.map(\.fhirJson))
        let allClaimed = retry.rows.allSatisfy(\.uploadClaimed)
        #expect(allClaimed)
        #expect(try staging.fetchCount(of: HealthUploadStaging.PendingDeletionRecord.self) == 1)
        try staging.remove(first)
        #expect(
            try staging.fetchCount(of: HealthUploadStaging.PendingSampleRecord.self) == 1,
            "Removing an old chunk must retain the redelivered row"
        )
        try staging.remove(retry)
        try await Self.drainRetraction(staging)
    }


    private func checkInterruptedStaging(failAfterStaging: Bool, at root: URL) async throws {
        let database = root.appending(path: "staging.sqlite3")
        let staging = try await HealthUploadStaging.resolvedForTesting(persistence: .onDisk(url: database))
        let sample = LedgerHarness.steps(0)
        let receipt = try await staging.add([sample])
        receipt.completeAfterSourceAcknowledgement()
        let observer = try DatabaseQueue(path: database.path(percentEncoded: false))
        if failAfterStaging {
            try await observer.write { db in
                try db.execute(sql: """
                    CREATE TRIGGER failRemoval BEFORE DELETE ON pendingSamples
                    BEGIN SELECT RAISE(ABORT, 'removal fails'); END
                    """)
            }
        }
        let originalPayload = Mutex<Data?>(nil)
        await #expect(throws: (any Error).self) {
            _ = try await HealthUploadStagingUploader.drainPendingSamples(
                from: staging, before: .distantFuture, maximumChunks: nil
            ) { url in
                try originalPayload.withLock { $0 = try Data(contentsOf: url) }
                try staging.add([try HKDeletedObject.make(uuid: sample.uuid)], ofType: .stepCount, deletedAfter: nil)
                if !failAfterStaging {
                    throw CancellationError()
                }
            }
        }
        try await observer.write { db in
            try db.execute(sql: "DROP TRIGGER IF EXISTS failRemoval")
        }

        let reopened = HealthUploadStaging(persistence: .onDisk(url: database))
        reopened.testing = staging.testing
        #expect(try reopened.elidePendingUploadsWherePossible().isEmpty)
        #expect(try reopened.fetchCount(of: HealthUploadStaging.PendingSampleRecord.self) == 1)
        #expect(try reopened.fetchCount(of: HealthUploadStaging.PendingDeletionRecord.self) == 1)
        _ = try await HealthUploadStagingUploader.drainPendingSamples(
            from: reopened, before: .distantFuture, maximumChunks: nil
        ) { url in
            let payload = try Data(contentsOf: url)
            let expectedPayload = originalPayload.withLock { $0 }
            #expect(payload == expectedPayload)
        }
        try await Self.drainRetraction(reopened)
        try observer.close()
    }
}
