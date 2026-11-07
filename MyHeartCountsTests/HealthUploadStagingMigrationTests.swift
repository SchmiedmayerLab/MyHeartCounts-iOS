//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GRDB
import GroveFHIRContract
import GroveFoundation
import GroveHealthKitFHIR
import HealthKit
@testable import MyHeartCounts
import Synchronization
import Testing


@Suite
struct HealthUploadStagingMigrationTests {
    /// One `pendingSamples` row, as a v4 database stores it.
    private struct V4Sample {
        let id = UUID()
        let sampleId = UUID()
        let fhirJson: Data
        var uploadClaimed = false

        func insert(into db: Database) throws {
            try db.execute(
                sql: """
                    INSERT INTO pendingSamples (id, timestamp, sampleType, sampleId, fhirJson, uploadClaimed)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [id, stagedAt, stepCount, sampleId, fhirJson, uploadClaimed]
            )
        }
    }

    /// One `pendingDeletions` row, as a v4 database stores it.
    private struct V4Deletion {
        let id = UUID()
        let sampleId = UUID()
        var deletedAfter: Date?

        func insert(into db: Database) throws {
            try db.execute(
                sql: "INSERT INTO pendingDeletions (id, timestamp, sampleType, sampleId, deletedAfter) VALUES (?, ?, ?, ?, ?)",
                arguments: [id, stagedAt, stepCount, sampleId, deletedAfter]
            )
        }
    }

    /// One object a drain staged through `stageUnreadable`, which may not be zstd-compressed.
    private struct UnreadableObject: Equatable {
        let name: String
        let contents: Data

        init(name: String, contents: Data) {
            self.name = name
            self.contents = contents
        }

        init(file: URL) throws {
            name = file.lastPathComponent
            contents = try Data(contentsOf: file)
        }
    }

    /// What one sample drain staged, and the integrity events it reported.
    private struct DrainedSamples {
        let files: StagedUploadFiles
        let unreadable: [UnreadableObject]
        let events: [HealthUploadIntegrityEvent]
    }

    /// When the rows of a v4 database were staged.
    private static let stagedAt = Date(timeIntervalSince1970: 1_700_000_000)
    /// The sample type of every row of a v4 database.
    private static let stepCount = HKQuantityTypeIdentifier.stepCount.rawValue

    private let expectedIndexes: Set<String> = [
        "pendingSamples_on_timestamp_sampleType",
        "pendingSamples_on_sampleType_timestamp",
        "pendingDeletions_on_timestamp_sampleType",
        "pendingDeletions_on_sampleType_timestamp"
    ]

    private static func compressed(_ json: String) throws -> Data {
        try Data(json.utf8).compressed(using: Zstd.self)
    }

    /// Migrates `dbQueue` as far as a v4 build did, and stores `samples` and `deletions` in it.
    private static func populateV4Database(
        _ dbQueue: DatabaseQueue,
        samples: [V4Sample] = [],
        deletions: [V4Deletion] = []
    ) async throws {
        try HealthUploadStaging.applyMigrations(to: dbQueue, upTo: "v4")
        try await dbQueue.write { db in
            for sample in samples {
                try sample.insert(into: db)
            }
            for deletion in deletions {
                try deletion.insert(into: db)
            }
        }
    }

    /// Staging opening a database a v4 build left behind, which holds `samples` and `deletions`. Its own subject is the
    /// harness's, so a test draining under another shows the drain doesn't read it.
    private static func migratedStaging(
        at root: URL,
        samples: [V4Sample] = [],
        deletions: [V4Deletion] = []
    ) async throws -> HealthUploadStaging {
        let database = root.appending(path: "healthObservations.sqlite3", directoryHint: .notDirectory)
        let dbQueue = try DatabaseQueue(path: database.path(percentEncoded: false))
        try await populateV4Database(dbQueue, samples: samples, deletions: deletions)
        try dbQueue.close()
        return try await HealthUploadStaging.resolvedForTesting(persistence: .onDisk(url: database))
    }

    /// Drains every staged sample under `subject`.
    private static func drainSamples(of staging: HealthUploadStaging, subject: FHIRExchangeSubject) async throws -> DrainedSamples {
        let files = StagedUploadFiles()
        let unreadable = Mutex<[UnreadableObject]>([])
        let events = Mutex<[HealthUploadIntegrityEvent]>([])
        let finished = try await HealthUploadStagingUploader.drainPendingSamples(
            from: staging,
            before: .distantFuture,
            maximumChunks: nil,
            subject: subject,
            stage: { url in
                try files.stage(url)
            },
            stageUnreadable: { url in
                let object = try UnreadableObject(file: url)
                unreadable.withLock { $0.append(object) }
            },
            integrityEvents: { event in
                events.withLock { $0.append(event) }
            }
        )
        #expect(finished)
        return DrainedSamples(files: files, unreadable: unreadable.withLock { $0 }, events: events.withLock { $0 })
    }

    @Test
    func v1DataReceivesDrainIndexes() async throws {
        let dbQueue = try DatabaseQueue()
        try HealthUploadStaging.applyMigrations(to: dbQueue, upTo: "v1")
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let sample = HealthUploadStaging.PendingSampleRecord(
            id: UUID(),
            timestamp: timestamp,
            sampleType: "sample",
            sampleId: UUID(),
            fhirJson: Data([0x00, 0x7F, 0xFF])
        )
        let deletionId = UUID()
        try await dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO pendingSamples (id, timestamp, sampleType, sampleId, fhirJson) VALUES (?, ?, ?, ?, ?)",
                arguments: [sample.id, sample.timestamp, sample.sampleType, sample.sampleId, sample.fhirJson]
            )
            try db.execute(
                sql: "INSERT INTO pendingDeletions (id, timestamp, sampleType, sampleId) VALUES (?, ?, ?, ?)",
                arguments: [deletionId, timestamp, "deletion", UUID()]
            )
        }

        try HealthUploadStaging.applyMigrations(to: dbQueue)
        try await dbQueue.read { db in
            let migrated = try HealthUploadStaging.PendingSampleRecord.fetchOne(db)
            let deletion = try HealthUploadStaging.PendingDeletionRecord.fetchOne(db)
            let timestampTypes = try timestampTypes(in: db)
            let indexes = try drainIndexes(in: db)
            #expect(migrated?.id == sample.id)
            #expect(migrated?.uploadClaimed == false)
            #expect(migrated?.payloadFormat == .legacyResource)
            #expect(deletion?.id == deletionId)
            #expect(deletion?.deletedAfter == nil)
            #expect(timestampTypes == ["TEXT", "TEXT"])
            #expect(indexes == expectedIndexes)
        }
    }

    /// H20: one v4 database can hold both legacy kinds, so the migration reads each row's own payload, and only its top
    /// level. A payload it can't read stays a resource, for the drain to upload as it is stored.
    @Test
    func v5ClassifiesEachRowByTheTopLevelResourceTypeOfItsPayload() async throws {
        let payloads: [(fhirJson: Data, format: HealthUploadStaging.PendingSampleRecord.PayloadFormat)] = [
            (try Self.compressed(#"{"resourceType":"Bundle","type":"collection"}"#), .legacyEventBundle),
            (try Self.compressed(#"{"entry":[{"resource":{"resourceType":"Observation"}}],"resourceType":"Bundle"}"#), .legacyEventBundle),
            (try Self.compressed(#"{"resourceType":"Observation","status":"final"}"#), .legacyResource),
            (try Self.compressed(#"{"contained":[{"resourceType":"Bundle"}],"resourceType":"Observation"}"#), .legacyResource),
            (try Self.compressed(#"[{"resourceType":"Bundle"}]"#), .legacyResource),
            (try Self.compressed(#"{"status":"final"}"#), .legacyResource),
            (try Self.compressed("not JSON"), .legacyResource),
            (Data(#"{"resourceType":"Bundle"}"#.utf8), .legacyResource),
            (Data([0x00, 0x7F, 0xFF]), .legacyResource)
        ]
        let samples = payloads.map { V4Sample(fhirJson: $0.fhirJson) }
        let dbQueue = try DatabaseQueue()
        try await Self.populateV4Database(dbQueue, samples: samples)

        try HealthUploadStaging.applyMigrations(to: dbQueue)

        let rows = try await dbQueue.read { db in
            try HealthUploadStaging.PendingSampleRecord.fetchAll(db)
        }
        let formats = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.payloadFormat) })
        #expect(rows.count == payloads.count)
        for (sample, payload) in zip(samples, payloads) {
            #expect(formats[sample.id] == payload.format)
        }
    }

    /// V11: no row staged before v5 records whose it is, so the migration states no subject, and changes nothing else.
    @Test
    func v5LeavesExistingRowsWithoutASubject() async throws {
        let sample = V4Sample(fhirJson: try Self.compressed(#"{"resourceType":"Observation"}"#), uploadClaimed: true)
        let deletion = V4Deletion(deletedAfter: Self.stagedAt - 3600)
        let dbQueue = try DatabaseQueue()
        try await Self.populateV4Database(dbQueue, samples: [sample], deletions: [deletion])

        try HealthUploadStaging.applyMigrations(to: dbQueue)

        try await dbQueue.read { db in
            let migratedSample = try #require(try HealthUploadStaging.PendingSampleRecord.fetchOne(db))
            let migratedDeletion = try #require(try HealthUploadStaging.PendingDeletionRecord.fetchOne(db))
            #expect(migratedSample.subjectSystem == nil)
            #expect(migratedSample.subjectValue == nil)
            #expect(migratedDeletion.subjectSystem == nil)
            #expect(migratedDeletion.subjectValue == nil)
            #expect(migratedSample.id == sample.id)
            #expect(migratedSample.sampleId == sample.sampleId)
            #expect(migratedSample.fhirJson == sample.fhirJson)
            #expect(migratedSample.uploadClaimed)
            #expect(migratedDeletion.id == deletion.id)
            #expect(migratedDeletion.sampleId == deletion.sampleId)
            #expect(migratedDeletion.deletedAfter == deletion.deletedAfter)
        }
    }

    private func timestampTypes(in db: Database) throws -> [String] {
        let timestamp = HealthUploadStaging.PendingSampleRecord.Columns.timestamp.name
        return try [
            HealthUploadStaging.PendingSampleRecord.databaseTableName,
            HealthUploadStaging.PendingDeletionRecord.databaseTableName
        ].map { table in
            try #require(db.columns(in: table).first { $0.name == timestamp }).type.uppercased()
        }
    }

    private func drainIndexes(in db: Database) throws -> Set<String> {
        let indexes = try [
            HealthUploadStaging.PendingSampleRecord.databaseTableName,
            HealthUploadStaging.PendingDeletionRecord.databaseTableName
        ].reduce(into: Set<String>()) { indexes, table in
            indexes.formUnion(try db.indexes(on: table).map(\.name))
        }
        return indexes.filter { !$0.hasPrefix("sqlite_") }
    }
}


// MARK: Draining migrated rows

extension HealthUploadStagingMigrationTests {
    /// V11, H20: a row that states no subject is the drain's, whichever subject that is, so nothing is removed as another
    /// subject's. Each legacy kind leaves as its own file of its stored elements, and an unreadable row as its stored bytes.
    @Test
    func migratedSamplesDrainAsTheDrainSubjects() async throws {
        try await withTemporaryRoot { root in
            let resource = Data(#"{"id":"resource","resourceType":"Observation"}"#.utf8)
            let eventBundle = Data(#"{"id":"event","resourceType":"Bundle","type":"collection"}"#.utf8)
            let corrupt = Data([0x00, 0x7F, 0xFF])
            let staging = try await Self.migratedStaging(at: root, samples: [
                V4Sample(fhirJson: try resource.compressed(using: Zstd.self)),
                V4Sample(fhirJson: try eventBundle.compressed(using: Zstd.self), uploadClaimed: true),
                V4Sample(fhirJson: corrupt)
            ])

            let drained = try await Self.drainSamples(of: staging, subject: try ExchangeHarness.otherSubject)

            let stepCount = Self.stepCount
            let legacyFiles = [splicedJSONArray([resource]), splicedJSONArray([eventBundle])]
            #expect(Set(drained.files.all) == Set(legacyFiles))
            #expect(Set(drained.files.names) == Set(legacyFiles.map { "\(stepCount)_\(HealthUploadBatch.digest(of: $0)).json.zstd" }))
            #expect(drained.unreadable == [
                UnreadableObject(name: "unreadable_\(stepCount)_\(HealthUploadBatch.digest(of: corrupt)).raw", contents: corrupt)
            ])
            #expect(drained.events == [HealthUploadIntegrityEvent(kind: .unreadable, sampleType: stepCount, rowCount: 1)])
            #expect(try staging.isEmpty)
        }
    }

    /// V11: a deletion that states no subject is retracted under the drain's, whichever subject that is.
    @Test
    func migratedDeletionsDrainAsTheDrainSubjects() async throws {
        try await withTemporaryRoot { root in
            let deletion = V4Deletion()
            let staging = try await Self.migratedStaging(at: root, deletions: [deletion])
            let subject = try ExchangeHarness.otherSubject
            let store = try staging.stateStore
            var retractions: [ExchangeRecord] = []

            let finished = try await HealthUploadStagingUploader.drainPendingDeletions(
                from: staging,
                before: .distantFuture,
                maximumChunks: nil,
                subject: subject,
                stage: { url in
                    let bundle = try Data(contentsOf: url).decompressed(using: Zstd.self)
                    retractions += try packedRecords(in: bundle, kind: .retraction)
                },
                stageUnreadable: { url in
                    Issue.record("A valid retraction left as \(url.lastPathComponent)")
                },
                integrityEvents: { event in
                    Issue.record("A row that states no subject reported \(event.kind.rawValue)")
                }
            )

            #expect(finished)
            let expected = try store.identityScope(subject: subject).sourceRecord(
                adapterID: "healthkit",
                sourceType: Self.stepCount,
                repositoryScope: try store.repositoryScope(.healthKit, subject: subject),
                nativeRecordID: deletion.sampleId.uuidString.lowercased()
            )
            #expect(retractions.map(\.sourceRecord) == [expected.identifier.identifier])
            #expect(try staging.isEmpty)
        }
    }

    /// Rule 7: a refused deletion states its subject, which for a row that stored none is the one the drain attributed it to.
    @Test
    func refusedMigratedDeletionStatesTheDrainSubject() async throws {
        try await withTemporaryRoot { root in
            let staging = try await Self.migratedStaging(at: root, deletions: [V4Deletion()])
            let subject = try ExchangeHarness.otherSubject
            var objects: [UnreadableObject] = []

            _ = try await HealthUploadStagingUploader.drainPendingDeletions(
                from: staging,
                before: .distantFuture,
                maximumChunks: nil,
                subject: subject,
                stage: { url in
                    Issue.record("A refused deletion left as \(url.lastPathComponent)")
                },
                stageUnreadable: { url in
                    objects.append(try UnreadableObject(file: url))
                },
                retractionOutcomes: { _, rows, _ in
                    rows.map { _ in .refused(.dependency("Forced")) }
                }
            )

            #expect(objects.count == 1)
            let object = try #require(objects.first)
            let members = try #require(
                try JSONSerialization.jsonObject(with: object.contents.decompressed(using: Zstd.self)) as? [String: Any]
            )
            #expect(members["subject"] as? [String: String] == [
                "system": subject.identity.system.rawValue,
                "value": subject.identity.value
            ])
            #expect(try staging.isEmpty)
        }
    }
}
