//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GRDB


// MARK: DB + Schema

extension HealthUploadStaging {
    // swiftlint:disable:next type_name
    protocol _PendingEntityRecord: Identifiable<UUID>, Codable, FetchableRecord, PersistableRecord, Sendable {
        static var timestampColumn: Column { get }
        static var sampleTypeColumn: Column { get }

        var timestamp: Date { get }
        var sampleType: String { get }
        var sampleId: UUID { get }
    }

    struct PendingSampleRecord: _PendingEntityRecord {
        enum Columns: String, CodingKey, ColumnExpression {
            case id
            case timestamp
            case sampleType
            case sampleId
            case fhirJson
        }
        static let databaseTableName = "pendingSamples"
        static var timestampColumn: Column { Column(Columns.timestamp.name) }
        static var sampleTypeColumn: Column { Column(Columns.sampleType.name) }
        let id: UUID
        let timestamp: Date
        let sampleType: String
        let sampleId: UUID
        /// zstd-compressed
        let fhirJson: Data
    }

    struct PendingDeletionRecord: _PendingEntityRecord {
        enum Columns: String, CodingKey, ColumnExpression {
            case id
            case timestamp
            case sampleType
            case sampleId
        }
        static let databaseTableName = "pendingDeletions"
        static var timestampColumn: Column { Column(Columns.timestamp.name) }
        static var sampleTypeColumn: Column { Column(Columns.sampleType.name) }
        let id: UUID
        let timestamp: Date
        let sampleType: String
        let sampleId: UUID
    }


    static func applyMigrations(to dbQueue: DatabaseQueue, upTo targetMigration: String? = nil) throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try createV1Schema(in: db)
        }
        migrator.registerMigration("v2") { db in
            try createDrainIndexes(in: db)
        }
        if let targetMigration {
            try migrator.migrate(dbQueue, upTo: targetMigration)
        } else {
            try migrator.migrate(dbQueue)
        }
    }

    private static func createV1Schema(in db: Database) throws {
        typealias DeletionColumn = PendingDeletionRecord.Columns
        try db.create(table: PendingDeletionRecord.databaseTableName, options: .strict) {
            $0.primaryKey(DeletionColumn.id.name, .blob).notNull()
            $0.column(DeletionColumn.timestamp.name, .text).notNull()
            $0.column(DeletionColumn.sampleType.name, .text).notNull()
            $0.column(DeletionColumn.sampleId.name, .blob).notNull()
            $0.uniqueKey([DeletionColumn.sampleType.name, DeletionColumn.sampleId.name], onConflict: .replace)
        }
        typealias SampleColumn = PendingSampleRecord.Columns
        try db.create(table: PendingSampleRecord.databaseTableName, options: .strict) {
            $0.primaryKey(SampleColumn.id.name, .blob).notNull()
            $0.column(SampleColumn.timestamp.name, .text).notNull()
            $0.column(SampleColumn.sampleType.name, .text).notNull()
            $0.column(SampleColumn.sampleId.name, .blob).notNull()
            $0.column(SampleColumn.fhirJson.name, .blob).notNull()
            $0.uniqueKey([SampleColumn.sampleType.name, SampleColumn.sampleId.name], onConflict: .replace)
        }
    }

    private static func createDrainIndexes(in db: Database) throws {
        let recordTypes: [any _PendingEntityRecord.Type] = [
            PendingSampleRecord.self,
            PendingDeletionRecord.self
        ]
        for recordType in recordTypes {
            try createDrainIndexes(in: db, for: recordType)
        }
    }

    private static func createDrainIndexes(
        in db: Database,
        for recordType: any _PendingEntityRecord.Type
    ) throws {
        let table = recordType.databaseTableName
        try db.create(
            index: "\(table)_on_timestamp_sampleType",
            on: table,
            columns: [recordType.timestampColumn.name, recordType.sampleTypeColumn.name],
            options: .ifNotExists
        )
        try db.create(
            index: "\(table)_on_sampleType_timestamp",
            on: table,
            columns: [recordType.sampleTypeColumn.name, recordType.timestampColumn.name],
            options: .ifNotExists
        )
    }

    func elidePendingUploads(in dbQueue: DatabaseQueue) throws -> [String: Int] {
        var summary: [String: Int] = [:]
        while true {
            let batch = try dbQueue.write { db -> [PendingRecordKey] in
                typealias SampleColumn = PendingSampleRecord.Columns
                typealias DeletionColumn = PendingDeletionRecord.Columns
                let sampleAlias = TableAlias<PendingSampleRecord>()
                let deletionAlias = TableAlias<PendingDeletionRecord>()
                let hasMatchingSample = PendingSampleRecord
                    .aliased(sampleAlias)
                    .filter(
                        sampleAlias[SampleColumn.sampleType] == deletionAlias[DeletionColumn.sampleType]
                            && sampleAlias[SampleColumn.sampleId] == deletionAlias[DeletionColumn.sampleId]
                    )
                    .exists()
                let keys = try PendingDeletionRecord
                    .aliased(deletionAlias)
                    .filter(hasMatchingSample)
                    .select(
                        deletionAlias[DeletionColumn.sampleType],
                        deletionAlias[DeletionColumn.sampleId]
                    )
                    .limit(Self.databaseWriteChunkSize)
                    .asRequest(of: PendingRecordKey.self)
                    .fetchAll(db)
                guard !keys.isEmpty else {
                    return []
                }
                let databaseKeys = keys.map(\.databaseKey)
                try PendingSampleRecord.filter(keys: databaseKeys).deleteAll(db)
                try PendingDeletionRecord.filter(keys: databaseKeys).deleteAll(db)
                return keys
            }
            guard !batch.isEmpty else {
                return summary
            }
            for key in batch {
                summary[key.sampleType, default: 0] += 1
            }
        }
    }
}


// MARK: Query Models

extension HealthUploadStaging {
    struct PendingRecordKey: Decodable, FetchableRecord, Hashable {
        enum Columns: String, CodingKey, ColumnExpression {
            case sampleType
            case sampleId
        }

        let sampleType: String
        let sampleId: UUID

        var databaseKey: [String: (any DatabaseValueConvertible)?] {
            [
                Columns.sampleType.name: sampleType,
                Columns.sampleId.name: sampleId
            ]
        }
    }

    struct SampleTypeCount: Decodable, FetchableRecord {
        enum Columns: String, CodingKey, ColumnExpression {
            case sampleType
            case count
        }

        let sampleType: String
        let count: Int
    }

    struct SampleTypeStats {
        let pendingUploads: [String: Int]
        let pendingDeletions: [String: Int]
    }

    func fetchSampleTypeStats() throws -> SampleTypeStats? {
        SampleTypeStats(
            pendingUploads: try fetchSampleTypeCounts(for: PendingSampleRecord.self),
            pendingDeletions: try fetchSampleTypeCounts(for: PendingDeletionRecord.self)
        )
    }
}
