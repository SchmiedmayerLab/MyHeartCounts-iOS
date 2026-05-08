//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

// swiftlint:disable all

import Algorithms
import Foundation
import GRDB
import Spezi
import SpeziFoundation
import Observation
//import SwiftUI


final class MHCFHIRStoreDatabase: Sendable {
    private let dbQueue: DatabaseQueue
    
    init(url: URL) throws {
        dbQueue = try DatabaseQueue(
            path: url.absoluteURL.resolvingSymlinksInPath().path(percentEncoded: false),
            configuration: GRDB::Configuration()
        )
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v0") { db in
            try db.create(table: Sample.databaseTableName, options: .strict) { table in
                table.primaryKey("id", .text)
                table.column("timestamp", .numeric) // unix timestamp
                table.column("sampleType", .text)
                table.column("sampleId", .text)
                table.column("fhir", .jsonText)
            }
            try db.create(table: Deletion.databaseTableName, options: .strict) { table in
                table.primaryKey("id", .text)
                table.column("timestamp", .numeric) // unix timestamp
                table.column("sampleType", .text)
                table.column("sampleId", .text)
            }
        }
        migrator.registerMigration("v1") { db in
            try db.rename(table: Sample.databaseTableName, column: "fhir", to: "fhirJson")
        }
        try migrator.migrate(dbQueue)
    }
}


// TODO move elsewhere!
extension Database {
    /// Renames a database table column.
    ///
    /// - throws: A ``DatabaseError`` whenever an SQLite error occurs.
    public func rename(table name: String, column oldName: String, to newName: String) throws {
        try execute(
            sql: "ALTER TABLE \(name.quotedDatabaseIdentifier) RENAME COLUMN \(oldName.quotedDatabaseIdentifier) TO \(newName.quotedDatabaseIdentifier)"
        )
    }
}


extension MHCFHIRStoreDatabase {
    // TODO (maybe file an issue w/ GRDB?) why can't i use FetchableRecord here? it has functions for fetchAll, fetchOne, etc.
    // why doesn't it also have fetchCount?
    func fetchCount(of type: (some TableRecord).Type) throws -> Int {
        try dbQueue.read { db in
            try type.fetchCount(db)
        }
    }
    
    
    func fetchSampleTypeCounts(for type: any _TableRecordWithSampleType.Type) throws -> [String: Int] {
        let results = try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT sampleType, COUNT(*) AS count
                FROM \(type.databaseTableName.quotedDatabaseIdentifier)
                GROUP BY sampleType
                """)
        }
        var retval: [String: Int] = [:]
        for row in results {
            let category: String = row["sampleType"]
            let count: Int = row["count"]
            retval[category, default: 0] += count
        }
        return retval
    }
    
    /// Unconditionally removes all data from the store.
    func clear() throws {
        try dbQueue.write { db in
            try Sample.deleteAll(db)
            try Deletion.deleteAll(db)
        }
    }
}


extension MHCFHIRStoreDatabase {
    protocol _TableRecordWithSampleType: TableRecord {
        var sampleType: String { get }
    }
    
    struct Sample: Identifiable, Codable, FetchableRecord, PersistableRecord, Sendable, _TableRecordWithSampleType {
        enum Columns {
            static let id = Column(CodingKeys.id)
            static let timestamp = Column(CodingKeys.timestamp)
            static let sampleType = Column(CodingKeys.sampleType)
            static let sampleId = Column(CodingKeys.sampleId)
            static let fhirJson = Column(CodingKeys.fhirJson)
        }
        
        static let databaseTableName = "samples"
        
        let id: UUID
        let timestamp: Date
        let sampleType: String
        let sampleId: UUID
        let fhirJson: String
    }
    
    
    struct Deletion: Identifiable, Codable, FetchableRecord, PersistableRecord, Sendable, _TableRecordWithSampleType {
        enum Columns {
            static let id = Column(CodingKeys.id)
            static let timestamp = Column(CodingKeys.timestamp)
            static let sampleType = Column(CodingKeys.sampleType)
            static let sampleId = Column(CodingKeys.sampleId)
        }
        
        static let databaseTableName = "deletions"
        
        let id: UUID
        let timestamp: Date
        let sampleType: String
        let sampleId: UUID
    }
    
    
//    struct DrainRun: Identifiable, Codable, FetchableRecord, PersistableRecord, Sendable {
//        enum Columns {
//            static let id = Column(CodingKeys.id)
//            static let timestamp = Column(CodingKeys.timestamp)
//        }
//        
//        static let databaseTableName = "drainRuns"
//        
//        let id: UUID
//        let timestamp: Date
//    }
    
    
    /// Inserts the samples into the database.
    func insert(samples: some Collection<Sample>) throws {
        guard !samples.isEmpty else {
            return
        }
        try dbQueue.write { db in
            for sample in samples {
                try sample.insert(db)
            }
        }
    }
    
    
    /// Inserts deletion records into the database, and removes any matching samples.
    func insert(deletions: some Collection<Deletion>) throws {
        guard !deletions.isEmpty else {
            return
        }
        var numElidedUploads = 0
        try dbQueue.write { db in
            for deletion in deletions {
                // try to delete any cached samples matching this deletion record
                let deletedCount = try Sample
                    .filter(Sample.Columns.sampleType == deletion.sampleType && Sample.Columns.sampleId == deletion.sampleId)
                    .deleteAll(db)
                numElidedUploads = deletedCount
                if deletedCount > 0 {
                    // if we managed to delete any matching samples, we also remove any pending deletions for this UUID & sampleType, if they exist
                    try Deletion
                        .filter(Deletion.Columns.sampleType == deletion.sampleType && Deletion.Columns.sampleId == deletion.sampleId)
                        .deleteAll(db)
                } else {
                    // otherwise, we record the deletion
                    try deletion.insert(db)
                }
            }
        }
        LocalPreferencesStore.standard[.numElidedHealthObservationUploads] += numElidedUploads
    }
}


extension LocalPreferenceKeys {
    // TODO have more fine-grained record-keeping here!
    // (day + sampleType + count?)
    static let numElidedHealthObservationUploads = LocalPreferenceKey("numElidedHealthObservationUploads", default: 0)
}


extension MHCFHIRStoreDatabase {
    struct DrainFetchResult: Sendable {
        let samples: [DrainBatch<Sample>]
        let deletions: [DrainBatch<Deletion>]
    }
    
    
    struct DrainBatch<Value: Sendable>: Sendable {
        let sampleType: String
        let rows: [Value]
    }
    
    
    func drainData(in range: PartialRangeUpTo<Date>) throws -> DrainFetchResult {
        try dbQueue.read { db in
            let samples = try Sample
                .filter(Sample.Columns.timestamp < range.upperBound)
                .order(Sample.Columns.sampleType)
                .fetchAll(db)
            let deletions = try Deletion
                .filter(Deletion.Columns.timestamp < range.upperBound)
                .order(Deletion.Columns.sampleType)
                .fetchAll(db)
            return DrainFetchResult(
                samples: samples.grouped(by: \.sampleType).reduce(into: []) { results, entry in
                    let (sampleType, samples) = entry
                    results.append(DrainBatch<Sample>(sampleType: sampleType, rows: samples))
                },
                deletions: deletions.grouped(by: \.sampleType).reduce(into: []) { results, entry in
                    let (sampleType, deletions) = entry
                    results.append(DrainBatch<Deletion>(sampleType: sampleType, rows: deletions))
                }
            )
        }
    }
}


//extension MHCFHIRStoreDatabase {
//    @propertyWrapper
//    struct QueryCount: DynamicProperty {
//        init
//    }
//}
