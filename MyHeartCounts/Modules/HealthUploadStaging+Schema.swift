//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Algorithms
import Foundation
import GRDB
import GroveFHIRContract
import GroveFoundation
import MyHeartCountsShared


// MARK: DB + Schema

extension HealthUploadStaging {
    // swiftlint:disable:next type_name
    protocol _PendingEntityRecord: Identifiable<UUID>, Codable, FetchableRecord, PersistableRecord, Sendable {
        static var timestampColumn: Column { get }
        static var sampleTypeColumn: Column { get }

        var timestamp: Date { get } // periphery:ignore - API
        var sampleType: String { get } // periphery:ignore - API
        var sampleId: UUID { get } // periphery:ignore - API
        /// The system of the subject the row is stored under; `nil` on a row staged before rows stored one.
        var subjectSystem: String? { get }
        /// The value of the subject the row is stored under; `nil` on a row staged before rows stored one.
        var subjectValue: String? { get }
    }

    struct PendingSampleRecord: _PendingEntityRecord {
        /// What a row's ``fhirJson`` holds.
        enum PayloadFormat: String, Codable, Sendable, DatabaseValueConvertible {
            /// An `ExchangeRecord.json`.
            case record
            /// A `ResourceProxy`, staged by the 4.0.7 App Store build.
            case legacyResource
            /// An exchange event Bundle, staged by a TestFlight build.
            case legacyEventBundle
        }

        enum Columns: String, CodingKey, ColumnExpression {
            case id
            case timestamp
            case sampleType
            case sampleId
            case fhirJson
            case uploadClaimed
            case payloadFormat
            case subjectSystem
            case subjectValue
        }
        static let databaseTableName = "pendingSamples"
        static var timestampColumn: Column { Column(Columns.timestamp.name) }
        static var sampleTypeColumn: Column { Column(Columns.sampleType.name) }
        let id: UUID
        let timestamp: Date
        let sampleType: String
        let sampleId: UUID
        /// The payload ``payloadFormat`` names, zstd-compressed.
        let fhirJson: Data
        /// Once a drain has taken this row, its addition may already be in the upload queue.
        var uploadClaimed = false
        var payloadFormat: PayloadFormat = .record
        var subjectSystem: String?
        var subjectValue: String?
    }

    struct PendingDeletionRecord: _PendingEntityRecord {
        enum Columns: String, CodingKey, ColumnExpression {
            case id
            case timestamp
            case sampleType
            case sampleId
            case deletedAfter
            case subjectSystem
            case subjectValue
        }
        static let databaseTableName = "pendingDeletions"
        static var timestampColumn: Column { Column(Columns.timestamp.name) }
        static var sampleTypeColumn: Column { Column(Columns.sampleType.name) }
        let id: UUID
        let timestamp: Date
        let sampleType: String
        let sampleId: UUID
        /// When the query before the one that reported the deletion was issued, if known.
        let deletedAfter: Date?
        var subjectSystem: String?
        var subjectValue: String?
    }


    static func applyMigrations(to dbQueue: DatabaseQueue, upTo targetMigration: String? = nil) throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try createV1Schema(in: db)
        }
        migrator.registerMigration("v2") { db in
            try createDrainIndexes(in: db)
        }
        migrator.registerMigration("v3") { db in
            try db.alter(table: PendingDeletionRecord.databaseTableName) {
                $0.add(column: PendingDeletionRecord.Columns.deletedAfter.name, .text)
            }
        }
        migrator.registerMigration("v4") { db in
            try db.alter(table: PendingSampleRecord.databaseTableName) {
                $0.add(column: PendingSampleRecord.Columns.uploadClaimed.name, .integer).notNull().defaults(to: false)
            }
        }
        migrator.registerMigration("v5") { db in
            try addPayloadFormatAndSubjectColumns(in: db)
            try classifyExistingPayloads(in: db)
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

    /// Every existing row keeps a `NULL` subject, as no row staged before records whose it is; a drain attributes such a
    /// row to its own subject.
    private static func addPayloadFormatAndSubjectColumns(in db: Database) throws {
        typealias SampleColumn = PendingSampleRecord.Columns
        typealias DeletionColumn = PendingDeletionRecord.Columns
        try db.alter(table: PendingSampleRecord.databaseTableName) {
            $0.add(column: SampleColumn.payloadFormat.name, .text)
                .notNull()
                .defaults(to: PendingSampleRecord.PayloadFormat.legacyResource.rawValue)
            $0.add(column: SampleColumn.subjectSystem.name, .text)
            $0.add(column: SampleColumn.subjectValue.name, .text)
        }
        try db.alter(table: PendingDeletionRecord.databaseTableName) {
            $0.add(column: DeletionColumn.subjectSystem.name, .text)
            $0.add(column: DeletionColumn.subjectValue.name, .text)
        }
    }

    /// Classifies each existing row by the top-level `resourceType` of its decompressed payload: a `Bundle` is a TestFlight
    /// build's event Bundle, and anything else, an undecodable payload included, stays a 4.0.7 resource.
    private static func classifyExistingPayloads(in db: Database) throws {
        struct Payload: Decodable {
            let resourceType: String?
        }
        typealias SampleColumn = PendingSampleRecord.Columns
        var eventBundleRows: [UUID] = []
        let rows = try Row.fetchCursor(db, PendingSampleRecord.select(SampleColumn.id, SampleColumn.fhirJson))
        while let row = try rows.next() {
            let json = try? (row[SampleColumn.fhirJson.name] as Data).decompressed(using: Zstd.self)
            if json.flatMap({ try? JSONDecoder().decode(Payload.self, from: $0) })?.resourceType == "Bundle" {
                eventBundleRows.append(row[SampleColumn.id.name])
            }
        }
        for rows in eventBundleRows.chunks(ofCount: databaseWriteChunkSize) {
            try PendingSampleRecord
                .filter(keys: rows)
                .updateAll(db, SampleColumn.payloadFormat.set(to: PendingSampleRecord.PayloadFormat.legacyEventBundle))
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

    static func fetchNextDrainChunk<R: _PendingEntityRecord>(
        of _: R.Type,
        before cutoff: Date,
        limit: Int,
        in db: Database
    ) throws -> DrainChunk<R>? {
        var request = R.filter(R.timestampColumn < cutoff)
        if R.self == PendingDeletionRecord.self {
            let samples = PendingSampleRecord.databaseTableName
            let deletions = PendingDeletionRecord.databaseTableName
            request = request.filter(sql: """
                NOT EXISTS (SELECT 1 FROM \(samples)
                WHERE \(samples).sampleType = \(deletions).sampleType AND \(samples).sampleId = \(deletions).sampleId)
                """)
        }
        guard let sampleType = try String.fetchOne(
            db,
            request
                .select(R.sampleTypeColumn)
                .order(R.timestampColumn, R.sampleTypeColumn)
                .limit(1)
        ) else {
            return nil
        }
        let rows = try request
            .filter(R.sampleTypeColumn == sampleType)
            .order(R.timestampColumn)
            .limit(limit)
            .fetchAll(db)
        return DrainChunk(sampleType: sampleType, rows: rows)
    }

    /// Whether a sample row and a deletion row are stored under the same subject, byte for byte; a `NULL` stored subject
    /// counts as equal, as a drain attributes such a row to its own subject.
    static func storedSubjectsMatch(
        _ sample: TableAlias<PendingSampleRecord>,
        _ deletion: TableAlias<PendingDeletionRecord>
    ) -> SQLExpression {
        typealias SampleColumn = PendingSampleRecord.Columns
        typealias DeletionColumn = PendingDeletionRecord.Columns
        return sample[SampleColumn.subjectSystem] == nil
            || deletion[DeletionColumn.subjectSystem] == nil
            || (sample[SampleColumn.subjectSystem] == deletion[DeletionColumn.subjectSystem]
                && sample[SampleColumn.subjectValue] == deletion[DeletionColumn.subjectValue])
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
                            && sampleAlias[SampleColumn.uploadClaimed] == false
                            && Self.storedSubjectsMatch(sampleAlias, deletionAlias)
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


// MARK: Subjects

extension HealthUploadStaging._PendingEntityRecord {
    /// Whether the row is `subject`'s: stored under it, byte for byte, or stored before rows recorded a subject, as a drain
    /// attributes such a row to its own subject.
    func isOwned(by subject: FHIRExchangeSubject) -> Bool {
        guard let subjectSystem, let subjectValue else {
            return true
        }
        return subject.isNamed(system: subjectSystem, value: subjectValue)
    }
}


extension FHIRExchangeSubject {
    /// The database counterpart of ``HealthUploadStaging/_PendingEntityRecord/isOwned(by:)``.
    var ownsStoredRow: SQLExpression {
        let system = Column(HealthUploadStaging.PendingSampleRecord.Columns.subjectSystem.name)
        let value = Column(HealthUploadStaging.PendingSampleRecord.Columns.subjectValue.name)
        return system == nil || (system == identity.system.rawValue && value == identity.value)
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
