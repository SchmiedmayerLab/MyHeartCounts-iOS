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
import GroveFoundation
import GroveHealthKit
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

    /// One drained chunk of deletions, ready for the upload staging the additions use.
    struct RetractionBatch: Sendable {
        let payload: Data
        let identifiers: [UUID]
        let receipt: HealthKitFHIRReservationReceipt
    }

    static let databaseWriteChunkSize = 500
    
    // swiftlint:disable attributes
    @ObservationIgnored @Dependency(HealthKit.self) private var healthKit
    @ObservationIgnored @Dependency(LocalStorage.self) private var localStorage
    @ObservationIgnored @Dependency(FirebaseConfiguration.self) private var firebaseConfiguration
    @ObservationIgnored private let dbQueue: DatabaseQueue?
    /// Whether, when inserting deletions, the `HealthUploadStaging` should automatically elide (i.e., identify and delete) any matching pending samples.
    @ObservationIgnored private let autoElideUploadsWhenInsertingDeletions: Bool
    // swiftlint:enable attributes
    
    #if DEBUG
    /// Set only by ``forTesting(persistence:autoElideUploadsWhenInsertingDeletions:subject:)``.
    @ObservationIgnored var testingSubject: FHIRExchangeSubject?
    /// An isolated ledger, so staging in a test never touches the host's encrypted exchange state.
    @ObservationIgnored var testingStateStore: FHIRExchangeStateStore?
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
            try? self.elidePendingUploadsWherePossible()
        }
    }

    /// The subject staged samples are attributed to.
    func resolvedSubject() async throws -> FHIRExchangeSubject {
        #if DEBUG
        if let testingSubject {
            return testingSubject
        }
        #endif
        return try await firebaseConfiguration.fhirExchangeSubject
    }

    /// The ledger staged samples reserve their exchange events in.
    func resolvedStateStore(accountDataGeneration: Int) -> FHIRExchangeStateStore {
        #if DEBUG
        if let testingStateStore {
            return testingStateStore
        }
        #endif
        return FHIRExchangeStateStore(
            localStorage: localStorage,
            accountDataGeneration: accountDataGeneration
        )
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
    @discardableResult
    func add(
        _ samples: consuming some Collection<some HealthObservation> & Sendable,
        commonSampleType: String? = nil,
        ingestionTimestamp: Date = .now,
        accountDataGeneration: Int? = nil
    ) async throws -> HealthKitFHIRReservationReceipt {
        guard !samples.isEmpty else {
            return HealthKitFHIRReservationReceipt()
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
        return try await _add(
            samples,
            commonSampleType: commonSampleType,
            ingestionTimestamp: ingestionTimestamp,
            writeContext: DatabaseWriteContext(
                dbQueue: dbQueue,
                accountDataGeneration: accountDataGeneration
            )
        )
    }
    
    /// - invariant: `samples` is not empty
    /// - invariant: each sample in `samples` is of type `commonSampleType`
    private func _add(
        _ samples: consuming some Collection<some HealthObservation> & Sendable,
        commonSampleType: String?,
        ingestionTimestamp: Date,
        writeContext: DatabaseWriteContext
    ) async throws -> HealthKitFHIRReservationReceipt {
        let subject = try await resolvedSubject()
        let stateStore = resolvedStateStore(accountDataGeneration: writeContext.accountDataGeneration)
        var pendingSamples: [PendingSampleRecord] = []
        var eventKeys = Set<String>()
        pendingSamples.reserveCapacity(Self.databaseWriteChunkSize)
        for observation in consume samples {
            try Task.checkCancellation()
            let payload = try await observation.prepareFHIRPayload(
                conversionInstant: ingestionTimestamp,
                subject: subject,
                stateStore: stateStore,
                using: healthKit
            )
            for entry in payload.entries {
                if let eventKey = entry.eventKey {
                    eventKeys.insert(eventKey)
                }
                let sampleType = entry.sourceTypeIdentifier == observation.sampleTypeIdentifier
                    ? commonSampleType ?? entry.sourceTypeIdentifier
                    : entry.sourceTypeIdentifier
                let fhirJson = try HealthUploadBatch.encoder.encode(entry.resource)
                pendingSamples.append(PendingSampleRecord(
                    id: UUID(),
                    timestamp: ingestionTimestamp,
                    sampleType: sampleType,
                    sampleId: entry.sourceID,
                    fhirJson: try (consume fhirJson).compressed(using: Zstd.self)
                ))
                if pendingSamples.count == Self.databaseWriteChunkSize {
                    try insert(
                        pendingSamples,
                        accountDataGeneration: writeContext.accountDataGeneration,
                        into: writeContext.dbQueue
                    )
                    pendingSamples.removeAll(keepingCapacity: true)
                }
            }
        }
        try insert(
            pendingSamples,
            accountDataGeneration: writeContext.accountDataGeneration,
            into: writeContext.dbQueue
        )
        return HealthKitFHIRReservationReceipt(stateStore: stateStore, eventKeys: eventKeys)
    }
    
    
    func add<Sample>(_ deletions: some Collection<HKDeletedObject> & Sendable, ofType sampleType: SampleType<Sample>) throws {
        guard !deletions.isEmpty else {
            return
        }
        guard let dbQueue else {
            throw DBError.noDatabase
        }
        let accountDataGeneration = LocalPreferencesStore.standard[.accountDataGeneration]
        try FHIRExchangeDestination.validateWrites(for: accountDataGeneration)
        let timestamp = Date()
        var pendingDeletions: [PendingDeletionRecord] = []
        pendingDeletions.reserveCapacity(Self.databaseWriteChunkSize)
        for deletion in deletions {
            pendingDeletions.append(PendingDeletionRecord(
                id: UUID(),
                timestamp: timestamp,
                sampleType: sampleType.id,
                sampleId: deletion.uuid
            ))
            if pendingDeletions.count == Self.databaseWriteChunkSize {
                try insertDeletions(
                    pendingDeletions,
                    accountDataGeneration: accountDataGeneration,
                    into: dbQueue
                )
                pendingDeletions.removeAll(keepingCapacity: true)
            }
        }
        try insertDeletions(
            pendingDeletions,
            accountDataGeneration: accountDataGeneration,
            into: dbQueue
        )
    }
    
    
    /// Inserts pending sample upload records into the database.
    ///
    /// - Note: This exists as a separate function, instead of being directly in the ``add(_:commonSampleType:ingestionTimestamp:accountDataGeneration:)`` function above,
    ///     to work around the compiler requiring us to call the async overload of `dbQueue.write` (because the `add` function is async).
    private func insert(
        _ pendingSamples: some Collection<PendingSampleRecord>,
        accountDataGeneration: Int,
        into dbQueue: DatabaseQueue
    ) throws {
        guard !pendingSamples.isEmpty else {
            return
        }
        try dbQueue.write { db in
            try FHIRExchangeDestination.validateWrites(for: accountDataGeneration)
            for sample in pendingSamples {
                try sample.insert(db)
            }
        }
    }

    /// Inserts deletion records into the database, and removes any matching samples.
    private func insertDeletions(
        _ deletions: some Collection<PendingDeletionRecord>,
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
                .select(PendingSampleRecord.Columns.sampleType, PendingSampleRecord.Columns.sampleId)
                .asRequest(of: PendingRecordKey.self)
                .fetchSet(db)
            let numElidedUploads = try PendingSampleRecord.filter(keys: keys).deleteAll(db)
            if !matchingKeys.isEmpty {
                try PendingDeletionRecord
                    .filter(keys: matchingKeys.map(\.databaseKey))
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
                )
                .exists()
            let counts = try PendingSampleRecord
                .aliased(sampleAlias)
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

extension HealthUploadStaging {
    struct DrainChunk<Value: _PendingEntityRecord>: Sendable {
        let sampleType: String
        let rows: [Value]
    }

    /// Fetches a bounded, single-sample-type chunk older than `cutoff`.
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
            guard let sampleType = try String.fetchOne(
                db,
                R
                    .select(R.sampleTypeColumn)
                    .filter(R.timestampColumn < cutoff)
                    .order(R.timestampColumn, R.sampleTypeColumn)
                    .limit(1)
            ) else {
                return nil
            }
            let rows = try R
                .filter(R.sampleTypeColumn == sampleType && R.timestampColumn < cutoff)
                .order(R.timestampColumn)
                .limit(limit)
                .fetchAll(db)
            return DrainChunk(sampleType: sampleType, rows: rows)
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
