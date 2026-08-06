//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GRDB
@testable import MyHeartCounts
import Testing


@Suite
struct HealthUploadStagingMigrationTests {
    private let expectedIndexes: Set<String> = [
        "pendingSamples_on_timestamp_sampleType",
        "pendingSamples_on_sampleType_timestamp",
        "pendingDeletions_on_timestamp_sampleType",
        "pendingDeletions_on_sampleType_timestamp"
    ]

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
        let deletion = HealthUploadStaging.PendingDeletionRecord(
            id: UUID(),
            timestamp: timestamp,
            sampleType: "deletion",
            sampleId: UUID()
        )
        try await dbQueue.write { db in
            try sample.insert(db)
            try deletion.insert(db)
        }

        try HealthUploadStaging.applyMigrations(to: dbQueue)
        try await dbQueue.read { db in
            let sampleId = try HealthUploadStaging.PendingSampleRecord.fetchOne(db)?.id
            let deletionId = try HealthUploadStaging.PendingDeletionRecord.fetchOne(db)?.id
            let timestampTypes = try timestampTypes(in: db)
            let indexes = try drainIndexes(in: db)
            #expect(sampleId == sample.id)
            #expect(deletionId == deletion.id)
            #expect(timestampTypes == ["TEXT", "TEXT"])
            #expect(indexes == expectedIndexes)
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
