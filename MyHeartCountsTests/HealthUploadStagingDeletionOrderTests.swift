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
    /// What a re-drain repeats of one staged Bundle: `Bundle.timestamp` is the packing time.
    private struct StagedBundle: Equatable {
        let name: String
        let entries: Data

        init(file: URL) throws {
            name = file.lastPathComponent
            let json = try Data(contentsOf: file).decompressed(using: Zstd.self)
            let bundle = try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
            entries = try JSONSerialization.data(withJSONObject: try #require(bundle["entry"]), options: .sortedKeys)
        }
    }

    /// Drains every staged sample through `stage`; none may leave as anything but a Bundle.
    private static func drainSamples(
        from staging: HealthUploadStaging,
        stage: @Sendable (URL) async throws -> Void
    ) async throws {
        _ = try await HealthUploadStagingUploader.drainPendingSamples(
            from: staging,
            before: .distantFuture,
            maximumChunks: nil,
            subject: try ExchangeHarness.subject,
            stage: stage,
            stageUnreadable: { url in
                Issue.record("A valid record left as \(url.lastPathComponent)")
            }
        )
    }

    private static func drainRetraction(_ staging: HealthUploadStaging) async throws {
        var retractions = 0
        _ = try await HealthUploadStagingUploader.drainPendingDeletions(
            from: staging,
            before: .distantFuture,
            maximumChunks: nil,
            subject: try ExchangeHarness.subject,
            stage: { _ in
                retractions += 1
            },
            stageUnreadable: { url in
                Issue.record("A valid retraction left as \(url.lastPathComponent)")
            }
        )
        #expect(retractions == 1)
        #expect(try staging.isEmpty)
    }

    @Test
    func deletionDuringStagingWaitsForTheAddition() async throws {
        let staging = try await HealthUploadStaging.resolvedForTesting()
        let subject = try ExchangeHarness.subject
        let sample = ExchangeHarness.steps(0)
        try await staging.add([sample])
        let additions = Mutex(0)

        try await Self.drainSamples(from: staging) { _ in
            try staging.add([try HKDeletedObject.make(uuid: sample.uuid)], ofType: .stepCount, deletedAfter: nil)
            #expect(try staging.fetchCount(of: HealthUploadStaging.PendingSampleRecord.self) == 1)
            #expect(try staging.fetchCount(of: HealthUploadStaging.PendingDeletionRecord.self) == 1)
            #expect(try staging.elidePendingUploadsWherePossible(dryRun: true).isEmpty)
            #expect(try staging.elidePendingUploadsWherePossible().isEmpty)
            // A concurrent or limited drain must not release the retraction while its addition is still being staged.
            _ = try await HealthUploadStagingUploader.drainPendingDeletions(
                from: staging,
                before: .distantFuture,
                maximumChunks: nil,
                subject: subject,
                stage: { _ in
                    Issue.record("The deletion overtook its addition")
                },
                stageUnreadable: { _ in
                    Issue.record("The deletion overtook its addition")
                }
            )
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

    /// H17: the claimed row may already be in the upload queue, so a redelivery leaves it as it is and adds no second version.
    @Test
    func redeliveryKeepsTheClaimedRow() async throws {
        let staging = try await HealthUploadStaging.resolvedForTesting()
        let sample = ExchangeHarness.steps(0)
        try await staging.add([sample])
        let first = try #require(try staging.claimNextSampleDrainChunk(before: .distantFuture, limit: 1))
        try await staging.add([sample])
        try staging.add([try HKDeletedObject.make(uuid: sample.uuid)], ofType: .stepCount, deletedAfter: nil)
        let retry = try #require(try staging.claimNextSampleDrainChunk(before: .distantFuture, limit: 1))

        #expect(retry.rows.map(\.id) == first.rows.map(\.id))
        #expect(retry.rows.map(\.fhirJson) == first.rows.map(\.fhirJson))
        let allClaimed = retry.rows.allSatisfy(\.uploadClaimed)
        #expect(allClaimed)
        #expect(try staging.fetchCount(of: HealthUploadStaging.PendingDeletionRecord.self) == 1)
        try staging.remove(first)
        #expect(
            try staging.fetchCount(of: HealthUploadStaging.PendingSampleRecord.self) == 0,
            "A redelivery of a claimed row adds no row"
        )
        try staging.remove(retry)
        try await Self.drainRetraction(staging)
    }


    private func checkInterruptedStaging(failAfterStaging: Bool, at root: URL) async throws {
        let database = root.appending(path: "staging.sqlite3")
        let staging = try await HealthUploadStaging.resolvedForTesting(persistence: .onDisk(url: database))
        let sample = ExchangeHarness.steps(0)
        try await staging.add([sample])
        let observer = try DatabaseQueue(path: database.path(percentEncoded: false))
        if failAfterStaging {
            try await observer.write { db in
                try db.execute(sql: """
                    CREATE TRIGGER failRemoval BEFORE DELETE ON pendingSamples
                    BEGIN SELECT RAISE(ABORT, 'removal fails'); END
                    """)
            }
        }
        let originalBundle = Mutex<StagedBundle?>(nil)
        await #expect(throws: (any Error).self) {
            try await Self.drainSamples(from: staging) { url in
                let bundle = try StagedBundle(file: url)
                originalBundle.withLock { $0 = bundle }
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
        try await Self.drainSamples(from: reopened) { url in
            let bundle = try StagedBundle(file: url)
            let expectedBundle = originalBundle.withLock { $0 }
            #expect(bundle == expectedBundle)
        }
        try await Self.drainRetraction(reopened)
        try observer.close()
    }
}
