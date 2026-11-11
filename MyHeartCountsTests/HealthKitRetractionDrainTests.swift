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
import Synchronization
import Testing


/// The deletion drain retracts each staged chunk through one exporter call, and stages it as one Retraction Bundle, whose
/// rows go only once the Bundle is staged.
@Suite
struct HealthKitRetractionDrainTests {
    private struct DrainedChunk {
        let name: String
        let payload: Data

        /// The Bundle's retraction records, in entry order.
        var records: [ExchangeRecord] {
            get throws {
                try packedRecords(in: payload, kind: .retraction)
            }
        }

        init(file: URL) throws {
            name = file.lastPathComponent
            payload = try Data(contentsOf: file).decompressed(using: Zstd.self)
        }
    }

    private struct Drain {
        var chunks: [DrainedChunk] = []
        /// How many rows each exporter call retracted.
        var retractedRows: [Int] = []
    }

    /// Stages deletions of `samples` of `sampleType`, as the anchored query reports them.
    private static func delete<Sample>(_ samples: [HKSample], ofType sampleType: SampleType<Sample>, in staging: HealthUploadStaging) throws {
        try staging.add(samples.map { try HKDeletedObject.make(uuid: $0.uuid) }, ofType: sampleType, deletedAfter: nil)
    }

    /// Drains every staged deletion, none of which may leave as anything but a Retraction Bundle.
    private static func drain(_ staging: HealthUploadStaging) async throws -> Drain {
        var chunks: [DrainedChunk] = []
        let retractedRows = Mutex<[Int]>([])
        let finished = try await HealthUploadStagingUploader.drainPendingDeletions(
            from: staging,
            before: .distantFuture,
            maximumChunks: nil,
            subject: try ExchangeHarness.subject,
            stage: { url in
                chunks.append(try DrainedChunk(file: url))
            },
            stageUnreadable: { url in
                Issue.record("A valid retraction left as \(url.lastPathComponent)")
            },
            retractionOutcomes: { staging, rows, subject in
                retractedRows.withLock { $0.append(rows.count) }
                return try await staging.retractionBatch(for: rows, subject: subject)
            },
            integrityEvents: { event in
                Issue.record("A healthy chunk reported \(event.kind.rawValue)")
            }
        )
        #expect(finished)
        return Drain(chunks: chunks, retractedRows: retractedRows.withLock { $0 })
    }

    /// The `entry` array of `bundle`, which states everything but the Bundle's own packing time.
    private static func entries(of bundle: Data) throws -> Data {
        let members = try #require(try JSONSerialization.jsonObject(with: bundle) as? [String: Any])
        return try JSONSerialization.data(withJSONObject: try #require(members["entry"]), options: .sortedKeys)
    }

    /// The retraction records of `outcomes`, in outcome order.
    private static func records(of outcomes: [HealthKitFHIRExporter.Retraction.Outcome]) -> [ExchangeRecord] {
        outcomes.compactMap { outcome -> ExchangeRecord? in
            guard case .record(let record) = outcome else {
                return nil
            }
            return record
        }
    }

    /// M4, M12: each chunk is one exporter call and one Retraction Bundle, which retracts the source records the deleted
    /// samples' additions delivered.
    @Test
    func drainRetractsEachChunkInOneCallIntoOneBundle() async throws {
        let staging = try await HealthUploadStaging.resolvedForTesting(autoElideUploadsWhenInsertingDeletions: false)
        let steps = (0..<3).map(ExchangeHarness.steps)
        let heartRates = (3..<5).map(heartRateSample)
        // Delivered and drained, so the deletions have no addition left to wait for.
        try await staging.add(steps)
        try await staging.add(heartRates)
        let delivered = try staging.drainStagedSamples().values.map { try ExchangeRecord(validating: $0).sourceRecord }
        #expect(delivered.count == 5)
        try Self.delete(steps, ofType: .stepCount, in: staging)
        try Self.delete(heartRates, ofType: .heartRate, in: staging)

        let drain = try await Self.drain(staging)

        #expect(drain.chunks.count == 2)
        #expect(drain.retractedRows.sorted() == [2, 3])
        #expect(try drain.chunks.map { try $0.records.count }.sorted() == [2, 3])
        #expect(Set(try drain.chunks.flatMap { try $0.records }.map(\.sourceRecord)) == Set(delivered))
        #expect(try staging.fetchCount(of: HealthUploadStaging.PendingDeletionRecord.self) == 0)
    }

    /// M12: a chunk's payload is its retraction records' validated entries, spliced in verbatim, under the name their keys
    /// give it.
    @Test
    func drainedBundleSplicesTheRetractionRecordsEntries() async throws {
        let staging = try await HealthUploadStaging.resolvedForTesting()
        try Self.delete((0..<3).map(ExchangeHarness.steps), ofType: .stepCount, in: staging)
        var staged: [DrainedChunk] = []
        let retracted = Mutex<[ExchangeRecord]>([])

        _ = try await HealthUploadStagingUploader.drainPendingDeletions(
            from: staging,
            before: .distantFuture,
            maximumChunks: nil,
            subject: try ExchangeHarness.subject,
            stage: { url in
                staged.append(try DrainedChunk(file: url))
            },
            stageUnreadable: { url in
                Issue.record("A valid retraction left as \(url.lastPathComponent)")
            },
            retractionOutcomes: { staging, rows, subject in
                let outcomes = try await staging.retractionBatch(for: rows, subject: subject)
                retracted.withLock { $0 += Self.records(of: outcomes) }
                return outcomes
            }
        )

        #expect(staged.count == 1)
        let chunk = try #require(staged.first)
        let records = retracted.withLock { $0 }
        #expect(records.count == 3)
        var packer = ExchangeBundlePacker(kind: .retraction)
        for record in records {
            let result = try packer.insert(record)
            #expect(result == .inserted)
        }
        let expected = try packer.bundle(packedAt: .now)
        #expect(try Self.entries(of: chunk.payload) == Self.entries(of: expected.json))
        #expect(try chunk.records.map(\.version) == records.map(\.version))
        #expect(chunk.name == HealthUploadBatch.filename(
            typePrefix: HKQuantityTypeIdentifier.stepCount.rawValue,
            provenanceFullURLs: records.map(\.version.fullURL),
            fileExtension: "json.zstd"
        ))
        #expect(try staging.isEmpty)
    }

    /// M7: a chunk whose rows could not be removed after staging its Bundle stays, so the next drain retracts it again under
    /// the same keys and the same file name.
    @Test
    func chunkIsRetractedAgainUntilItsRowsAreRemoved() async throws {
        try await withTemporaryRoot { root in
            let database = root.appending(path: "healthObservations.sqlite3", directoryHint: .notDirectory)
            let staging = try await HealthUploadStaging.resolvedForTesting(persistence: .onDisk(url: database))
            try Self.delete((0..<3).map(ExchangeHarness.steps), ofType: .stepCount, in: staging)
            // Another connection makes removing the drained rows fail.
            let saboteur = try DatabaseQueue(path: database.path(percentEncoded: false))
            try await saboteur.write { db in
                try db.execute(sql: """
                    CREATE TRIGGER failRemoval BEFORE DELETE ON pendingDeletions
                    BEGIN SELECT RAISE(ABORT, 'removal fails'); END
                    """)
            }

            var failedChunk: DrainedChunk?
            await #expect(throws: (any Error).self) {
                _ = try await HealthUploadStagingUploader.drainPendingDeletions(
                    from: staging,
                    before: .distantFuture,
                    maximumChunks: nil,
                    subject: try ExchangeHarness.subject,
                    stage: { url in
                        failedChunk = try DrainedChunk(file: url)
                    },
                    stageUnreadable: { url in
                        Issue.record("A valid retraction left as \(url.lastPathComponent)")
                    }
                )
            }
            #expect(try staging.fetchCount(of: HealthUploadStaging.PendingDeletionRecord.self) == 3)

            try await saboteur.write { db in
                try db.execute(sql: "DROP TRIGGER failRemoval")
            }
            let drained = try await Self.drain(staging).chunks
            let failed = try #require(failedChunk)
            #expect(drained.map(\.name) == [failed.name])
            #expect(try drained.flatMap { try $0.records }.map(\.version) == failed.records.map(\.version))
            #expect(try staging.fetchCount(of: HealthUploadStaging.PendingDeletionRecord.self) == 0)
            try saboteur.close()
        }
    }
}
