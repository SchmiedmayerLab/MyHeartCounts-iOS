//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Dispatch
import Foundation
import GRDB
import Grove
import GroveFHIRContract
import GroveFoundation
import GroveHealthKit
import GroveHealthKitFHIR
import GroveLocalStorage
import HealthKit
import MyHeartCountsShared

@Observable
final class HealthUploadStaging: Grove::Module, EnvironmentAccessible, @unchecked Sendable {
    private enum DBError: Error {
        /// Thrown if some database operation fails because there is no database (because creation failed).
        case noDatabase
    }
    
    enum Persistence {
        case onDisk(url: URL)
        case inMemory

        fileprivate static let defaultDatabaseUrl = URL.documentsDirectory.appendingPathComponent("healthObservations.sqlite3")

        static var onDisk: Self {
            .onDisk(url: defaultDatabaseUrl)
        }
    }

    private struct DatabaseWriteContext {
        let dbQueue: DatabaseQueue
        let accountDataGeneration: Int
    }

    static let databaseWriteChunkSize = 500
    
    // swiftlint:disable attributes
    @ObservationIgnored @Dependency(HealthKit.self) private var healthKit
    @ObservationIgnored @Dependency(LocalStorage.self) private var localStorage
    @ObservationIgnored @Dependency(FirebaseConfiguration.self) private var firebaseConfiguration
    @ObservationIgnored @Dependency(HealthKitExporterHolder.self) var healthKitExporterHolder
    @ObservationIgnored private let dbQueue: DatabaseQueue?
    /// Whether, when inserting deletions, the `HealthUploadStaging` should automatically elide (i.e., identify and delete) any matching pending samples.
    @ObservationIgnored private let autoElideUploadsWhenInsertingDeletions: Bool
    // swiftlint:enable attributes
    
    #if DEBUG
    /// What a test stages against instead of the account and the app's exchange state; set only by
    /// ``forTesting(persistence:autoElideUploadsWhenInsertingDeletions:subject:)``.
    @ObservationIgnored var testing: TestingOverrides?
    #endif

    nonisolated init(
        persistence: Persistence,
        autoElideUploadsWhenInsertingDeletions: Bool = true
    ) {
        self.autoElideUploadsWhenInsertingDeletions = autoElideUploadsWhenInsertingDeletions
        do {
            let dbQueue: DatabaseQueue
            switch persistence {
            case .onDisk(let url):
                var configuration = GRDB::Configuration()
                configuration.journalMode = .wal
                dbQueue = try DatabaseQueue(
                    path: url.absoluteURL.resolvingSymlinksInPath().path(percentEncoded: false),
                    configuration: configuration
                )
            case .inMemory:
                dbQueue = try DatabaseQueue()
            }
            try Self.applyMigrations(to: dbQueue)
            switch persistence {
            case .inMemory:
                break
            case .onDisk(let url):
                if url.standardizedFileURL == Persistence.defaultDatabaseUrl.standardizedFileURL {
                    Self.excludeStoreFromBackup(at: url)
                }
            }
            self.dbQueue = dbQueue
        } catch {
            print("Error creating db: \(error)")
            dbQueue = nil
        }
    }

    private static func excludeStoreFromBackup(at databaseUrl: URL) {
        let fileManager = FileManager.default
        for suffix in ["-wal", "-shm", ""] {
            var url = URL(fileURLWithPath: databaseUrl.path(percentEncoded: false) + suffix)
            guard fileManager.fileExists(atPath: url.path(percentEncoded: false)) else {
                continue
            }
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            do {
                try url.setResourceValues(resourceValues)
            } catch {
                print("Unable to exclude \(url.lastPathComponent) from backup: \(error)")
            }
        }
    }
    
    func configure() {
        Task(priority: .utility) {
            try? self.elidePendingUploadsAtLaunch()
        }
    }
}


extension HealthUploadStaging {
    var isEmpty: Bool {
        get throws {
            guard let dbQueue else {
                return true
            }
            return try dbQueue.read { db in
                try PendingSampleRecord.fetchCount(db) == 0
                    && PendingDeletionRecord.fetchCount(db) == 0
            }
        }
    }
}


// MARK: Insertion

extension HealthUploadStaging {
    func add(
        _ samples: consuming some Collection<some HealthObservation> & Sendable,
        commonSampleType: String? = nil,
        ingestionTimestamp: Date = .now,
        accountDataGeneration: Int? = nil
    ) async throws {
        guard !samples.isEmpty else {
            return
        }
        guard let dbQueue else {
            throw DBError.noDatabase
        }
        let accountDataGeneration = accountDataGeneration
            ?? LocalPreferencesStore.standard[.accountDataGeneration]
        try FHIRExchangeDestination.validateWrites(for: accountDataGeneration)
        if let commonSampleType {
            assert(samples.allSatisfy { $0.sampleTypeIdentifier == commonSampleType })
        }
        try await _add(
            samples,
            ingestionTimestamp: ingestionTimestamp,
            writeContext: DatabaseWriteContext(
                dbQueue: dbQueue,
                accountDataGeneration: accountDataGeneration
            )
        )
    }
    
    /// Converts the batch off the caller's actor and stages one row per entry, in writes of ``databaseWriteChunkSize``.
    ///
    /// Every row stores its record's bytes, and the subject its exporter converted for.
    ///
    /// - invariant: `samples` is not empty
    @concurrent
    private func _add<Observations: Collection & Sendable>(
        _ samples: consuming Observations,
        ingestionTimestamp: Date,
        writeContext: DatabaseWriteContext
    ) async throws where Observations.Element: HealthObservation {
        // Refused before the exporter is built, which reads the identity secret and the app facts.
        guard !(Observations.Element.self is any SelfModelledHealthObservation.Type) else {
            throw MyHeartCountsStandard.HealthObservationUploadError.unsupportedStrategy
        }
        var pendingSamples: [PendingSampleRecord] = []
        pendingSamples.reserveCapacity(Self.databaseWriteChunkSize)
        let current = try await stagingExporter(accountDataGeneration: writeContext.accountDataGeneration)
        _ = try await Observations.Element.export(
            consume samples,
            at: ingestionTimestamp,
            recordProvider: .healthKit(healthKit),
            exporter: current.exporter
        ) { entry in
            pendingSamples.append(PendingSampleRecord(
                id: UUID(),
                timestamp: ingestionTimestamp,
                sampleType: entry.sourceTypeIdentifier,
                sampleId: entry.sourceID,
                fhirJson: try entry.exchangeRecord().json.compressed(using: Zstd.self),
                subjectSystem: current.subject.identity.system.rawValue,
                subjectValue: current.subject.identity.value
            ))
            if pendingSamples.count == Self.databaseWriteChunkSize {
                try insert(
                    pendingSamples,
                    subject: current.subject,
                    accountDataGeneration: writeContext.accountDataGeneration,
                    into: writeContext.dbQueue
                )
                pendingSamples.removeAll(keepingCapacity: true)
            }
        }
        try insert(
            pendingSamples,
            subject: current.subject,
            accountDataGeneration: writeContext.accountDataGeneration,
            into: writeContext.dbQueue
        )
    }
    
    
    func add<Sample>(
        _ deletions: some Collection<HKDeletedObject> & Sendable,
        ofType sampleType: SampleType<Sample>,
        deletedAfter: Date?
    ) throws {
        guard !deletions.isEmpty else {
            return
        }
        guard let dbQueue else {
            throw DBError.noDatabase
        }
        let accountDataGeneration = LocalPreferencesStore.standard[.accountDataGeneration]
        try FHIRExchangeDestination.validateWrites(for: accountDataGeneration)
        let subject = try stagingSubject(accountDataGeneration: accountDataGeneration)
        let timestamp = Date()
        var pendingDeletions: [PendingDeletionRecord] = []
        pendingDeletions.reserveCapacity(Self.databaseWriteChunkSize)
        for deletion in deletions {
            pendingDeletions.append(PendingDeletionRecord(
                id: UUID(),
                timestamp: timestamp,
                sampleType: sampleType.id,
                sampleId: deletion.uuid,
                deletedAfter: deletedAfter,
                subjectSystem: subject.identity.system.rawValue,
                subjectValue: subject.identity.value
            ))
            if pendingDeletions.count == Self.databaseWriteChunkSize {
                try insertDeletions(
                    pendingDeletions,
                    subject: subject,
                    accountDataGeneration: accountDataGeneration,
                    into: dbQueue
                )
                pendingDeletions.removeAll(keepingCapacity: true)
            }
        }
        try insertDeletions(
            pendingDeletions,
            subject: subject,
            accountDataGeneration: accountDataGeneration,
            into: dbQueue
        )
    }
    
    
    /// Inserts pending sample upload records of `subject` into the database.
    ///
    /// A redelivery of a row a drain claimed for the same subject is skipped: the claimed row may already be in the upload
    /// queue, and a replacement would survive the chunk's removal, which goes by row id, and leave as a second version.
    /// HealthKit samples are immutable, so keeping the row loses nothing. Any other row of the same sample is replaced.
    ///
    /// - Note: This exists as a separate function, instead of being directly in the ``add(_:commonSampleType:ingestionTimestamp:accountDataGeneration:)`` function above,
    ///     to work around the compiler requiring us to call the async overload of `dbQueue.write` (because the `add` function is async).
    private func insert(
        _ pendingSamples: some Collection<PendingSampleRecord>,
        subject: FHIRExchangeSubject,
        accountDataGeneration: Int,
        into dbQueue: DatabaseQueue
    ) throws {
        guard !pendingSamples.isEmpty else {
            return
        }
        try dbQueue.write { db in
            try FHIRExchangeDestination.validateWrites(for: accountDataGeneration)
            for sample in pendingSamples {
                let numClaimedRows = try PendingSampleRecord
                    .filter(
                        PendingSampleRecord.Columns.sampleType == sample.sampleType
                            && PendingSampleRecord.Columns.sampleId == sample.sampleId
                            && PendingSampleRecord.Columns.uploadClaimed == true
                    )
                    .filter(subject.ownsStoredRow)
                    .fetchCount(db)
                if numClaimedRows == 0 {
                    try sample.insert(db)
                }
            }
        }
    }

    /// Inserts deletion records of `subject` into the database, and removes any matching samples of that subject.
    ///
    /// The row of another subject's sample is left to the drain, and the deletion is inserted.
    private func insertDeletions(
        _ deletions: some Collection<PendingDeletionRecord>,
        subject: FHIRExchangeSubject,
        accountDataGeneration: Int,
        into dbQueue: DatabaseQueue
    ) throws {
        guard !deletions.isEmpty else {
            return
        }
        try dbQueue.write { db in
            try FHIRExchangeDestination.validateWrites(for: accountDataGeneration)
            guard autoElideUploadsWhenInsertingDeletions else {
                for deletion in deletions {
                    try deletion.insert(db)
                }
                return
            }
            let deletionsByKey = Dictionary(deletions.map { deletion in
                (PendingRecordKey(sampleType: deletion.sampleType, sampleId: deletion.sampleId), deletion)
            }, uniquingKeysWith: { _, latest in latest })
            let keys = deletionsByKey.keys.map(\.databaseKey)
            let matchingKeys = try PendingSampleRecord
                .filter(keys: keys)
                .filter(PendingSampleRecord.Columns.uploadClaimed == false)
                .filter(subject.ownsStoredRow)
                .select(PendingSampleRecord.Columns.sampleType, PendingSampleRecord.Columns.sampleId)
                .asRequest(of: PendingRecordKey.self)
                .fetchSet(db)
            let numElidedUploads = try PendingSampleRecord
                .filter(keys: matchingKeys.map(\.databaseKey))
                .deleteAll(db)
            if !matchingKeys.isEmpty {
                try PendingDeletionRecord
                    .filter(keys: matchingKeys.map(\.databaseKey))
                    .filter(subject.ownsStoredRow)
                    .deleteAll(db)
            }
            for (key, deletion) in deletionsByKey where !matchingKeys.contains(key) {
                try deletion.insert(db)
            }
            if numElidedUploads > 0 {
                LocalPreferencesStore.standard[.numElidedHealthObservationUploads] += numElidedUploads
            }
        }
    }

    /// Removes pending samples and deletions that cancel each other out.
    @discardableResult
    func elidePendingUploadsWherePossible(dryRun: Bool = false) throws -> [String: Int] {
        guard let dbQueue else {
            throw DBError.noDatabase
        }
        if !dryRun {
            return try elidePendingUploads(in: dbQueue)
        }
        typealias SampleCol = PendingSampleRecord.Columns
        typealias DeletionCol = PendingDeletionRecord.Columns
        return try dbQueue.read { db in
            let sampleAlias = TableAlias<PendingSampleRecord>()
            let deletionAlias = TableAlias<PendingDeletionRecord>()
            let hasMatchingDeletion = PendingDeletionRecord
                .aliased(deletionAlias)
                .filter(
                    deletionAlias[DeletionCol.sampleType] == sampleAlias[SampleCol.sampleType]
                        && deletionAlias[DeletionCol.sampleId] == sampleAlias[SampleCol.sampleId]
                        && Self.storedSubjectsMatch(sampleAlias, deletionAlias)
                )
                .exists()
            let counts = try PendingSampleRecord
                .aliased(sampleAlias)
                .filter(sampleAlias[SampleCol.uploadClaimed] == false)
                .filter(hasMatchingDeletion)
                .select(
                    sampleAlias[SampleCol.sampleType],
                    count(sampleAlias[SampleCol.sampleId]).forKey(SampleTypeCount.Columns.count)
                )
                .group(sampleAlias[SampleCol.sampleType])
                .asRequest(of: SampleTypeCount.self)
                .fetchAll(db)
            return Dictionary(uniqueKeysWithValues: counts.map { ($0.sampleType, $0.count) })
        }
    }
}

// MARK: Other

extension LocalPreferenceKeys {
    // maybe have more fine-grained record-keeping here!
    // (day + sampleType + count?)
    static let numElidedHealthObservationUploads = LocalPreferenceKey("numElidedHealthObservationUploads", default: 0)
}


extension HealthUploadStaging {
    func fetchCount(of type: (some TableRecord).Type) throws -> Int {
        guard let dbQueue else {
            throw DBError.noDatabase
        }
        return try dbQueue.read { db in
            try type.fetchCount(db)
        }
    }
    
    
    func fetchSampleTypeCounts<Record: _PendingEntityRecord>(for type: Record.Type) throws -> [String: Int] {
        guard let dbQueue else {
            throw DBError.noDatabase
        }
        let counts = try dbQueue.read { db in
            try type
                .select(
                    type.sampleTypeColumn,
                    count(type.sampleTypeColumn).forKey(SampleTypeCount.Columns.count)
                )
                .group(type.sampleTypeColumn)
                .asRequest(of: SampleTypeCount.self)
                .fetchAll(db)
        }
        return Dictionary(uniqueKeysWithValues: counts.map { ($0.sampleType, $0.count) })
    }
    
    /// Unconditionally removes all data from the store.
    func clear() throws {
        guard let dbQueue else {
            throw DBError.noDatabase
        }
        try dbQueue.write { db in
            try PendingSampleRecord.deleteAll(db)
            try PendingDeletionRecord.deleteAll(db)
        }
    }
}

#if DEBUG
extension HealthUploadStaging {
    /// Runs `body` on the staging's own database, so a test can stage or read a row no insert path writes.
    func writeForTesting<R>(_ body: (Database) throws -> R) throws -> R {
        guard let dbQueue else {
            throw DBError.noDatabase
        }
        return try dbQueue.write(body)
    }
}
#endif


extension HealthUploadStaging {
    struct DrainChunk<Value: _PendingEntityRecord>: Sendable {
        let sampleType: String
        let rows: [Value]
    }

    /// Fetches a bounded, single-sample-type chunk older than `cutoff`.
    /// Deletions wait until any matching addition has been durably staged and removed.
    func fetchNextDrainChunk<R: _PendingEntityRecord>(
        of _: R.Type,
        before cutoff: Date,
        limit: Int
    ) throws -> DrainChunk<R>? {
        guard let dbQueue else {
            throw DBError.noDatabase
        }
        precondition(limit > 0)
        return try dbQueue.read { db in
            try Self.fetchNextDrainChunk(of: R.self, before: cutoff, limit: limit, in: db)
        }
    }

    /// Claims a chunk in the same transaction that reads it, before any asynchronous file staging.
    /// Claims survive cancellation and process death: retries keep both the addition and any later deletion.
    func claimNextSampleDrainChunk(before cutoff: Date, limit: Int) throws -> DrainChunk<PendingSampleRecord>? {
        guard let dbQueue else {
            throw DBError.noDatabase
        }
        precondition(limit > 0)
        return try dbQueue.write { db in
            guard let chunk = try Self.fetchNextDrainChunk(of: PendingSampleRecord.self, before: cutoff, limit: limit, in: db) else {
                return nil
            }
            try PendingSampleRecord.filter(keys: chunk.rows.map(\.id))
                .updateAll(db, PendingSampleRecord.Columns.uploadClaimed.set(to: true))
            return DrainChunk(sampleType: chunk.sampleType, rows: chunk.rows.map { row in
                var row = row
                row.uploadClaimed = true
                return row
            })
        }
    }

    func remove<R>(_ drainChunk: DrainChunk<R>) throws {
        guard let dbQueue else {
            throw DBError.noDatabase
        }
        try dbQueue.write { db in
            _ = try R.deleteAll(db, keys: drainChunk.rows.lazy.map(\.id))
        }
    }
}
