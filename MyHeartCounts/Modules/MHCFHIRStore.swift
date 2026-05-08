//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

// swiftlint:disable all

import AsyncAlgorithms
import Dispatch
import Foundation
import HealthKit
import struct ModelsR4.FHIRPrimitive
import struct ModelsR4.Instant
import SQLite
import SQLite3
import Spezi
import Observation
import SpeziHealthKit
import MyHeartCountsShared


@globalActor
actor MHCFHIRStoreActor {
    static let shared = MHCFHIRStoreActor()
    
    nonisolated private let queue: DispatchSerialQueue
    
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }
    
    private init() {
        let queue = DispatchQueue(label: "edu.stanford.MHC.MHCFHIRStoreActor")
        guard let queue = queue as? DispatchSerialQueue else {
            preconditionFailure("Dispatch queue \(queue.label) was not initialized to be serial!")
        }
        self.queue = queue
    }
}


func isSendable(_: some Sendable) {}
func isSendable(_: (some Sendable).Type) {}


@Observable
final class MHCFHIRStore: Spezi::Module, EnvironmentAccessible, @unchecked Sendable {
    @ObservationIgnored @Dependency(HealthKit.self) private var healthKit
    
    @ObservationIgnored private let db: MHCFHIRStoreDatabase?
    
//    // would ideally be immutable and initialized in the init, but that doesn't work
//    // bc of the actor isolation. (See also https://github.com/swiftlang/swift/issues/87690)
//    @ObservationIgnored @MHCFHIRStoreActor private var db: Connection?
//    
//    @ObservationIgnored private let samples = Table("samples")
//    @ObservationIgnored private let deletions = Table("deletions")
//    
//    //    /// The id (primary key) of this entry within the table.
//    //    /// - Important: Not a HealthKit-assigned id!
//    //    private let id = SQLite.Expression<UInt64>("id")
//    
//    /// When the app was informed about this record.
//    @ObservationIgnored private let timestamp = SQLite.Expression<Date>("timestamp")
//    @ObservationIgnored private let sampleType = SQLite.Expression<String>("sampleType")
//    @ObservationIgnored private let sampleId = SQLite.Expression<UUID>("sampleId")
//    @ObservationIgnored private let fhirJson = SQLite.Expression<String>("fhirJson")
    
    @ObservationIgnored private let jsonEncoder = JSONEncoder()
    
    @MainActor private(set) var numberOfSamples: Int = 0
    @MainActor private(set) var numberOfDeletions: Int = 0
    
    nonisolated init() {
        let url = URL.documentsDirectory.appendingPathComponent("healthObservations.sqlite3")
        do {
            db = try MHCFHIRStoreDatabase(url: url)
        } catch {
            print("Error creating db: \(error)")
            db = nil
        }
    }
    
    @MHCFHIRStoreActor
    private func setupObservers() {
        guard let db else {
            return
        }
        db.updateHook { operation, _, table, rowId in
            switch table {
            case "samples":
                let size = try! db.scalar(self.samples.count)
                Task { @MainActor in
                    self.numberOfSamples = size
                }
            case "deletions":
                let size = try! db.scalar(self.deletions.count)
                Task { @MainActor in
                    self.numberOfDeletions = size
                }
            default:
                break
            }
        }
    }
    
    /// Unconditionally removes all data from the store.
    @MHCFHIRStoreActor
    func clear() throws {
        guard let db else {
            return
        }
        try db.transaction {
            try db.run(samples.delete())
            try db.run(deletions.delete())
        }
    }
}


extension MHCFHIRStore {
    @MHCFHIRStoreActor
    func takeData(upTo cutoffTimestamp: Date) throws {
    }
}


// MARK: Insertion

extension MHCFHIRStore {
    func add<Sample>(samples: some Collection<Sample> & Sendable, ofType sampleType: SampleType<Sample>) async throws {
        try await add(samples: samples, commonSampleType: sampleType.id)
    }
    
    func add(
        samples: consuming some Collection<some HealthObservation> & Sendable,
        commonSampleType: String? = nil,
        postprocessResource: @Sendable (FHIRResource) throws -> Void = { _ in }
    ) async throws {
        let timestamp = Date()
        let issuedDate = FHIRPrimitive<ModelsR4.Instant>(try .init(date: timestamp))
        let fhirSamples: [MHCFHIRStoreDatabase.Sample] = try await (consume samples).async.reduce(into: []) { results, observation in
            let sampleType = commonSampleType ?? observation.sampleTypeIdentifier
            let sampleId = observation.id
            let resource = try await observation.turnIntoFHIRResource(
                issuedDate: issuedDate,
                using: healthKit,
                postprocess: postprocessResource
            )
            let fhirJson = try jsonEncoder.encode(consume resource)
            results.append(MHCFHIRStoreDatabase.Sample(
                timestamp: timestamp,
                sampleType: sampleType,
                sampleId: sampleId,
                fhirJson: String(decoding: consume fhirJson, as: UTF8.self)
            ))
        }
        try await db.insert(samples: fhirSamples)
    }
    
    @MHCFHIRStoreActor
    func add<Sample>(deletions: some Collection<HKDeletedObject> & Sendable, ofType sampleType: SampleType<Sample>) async throws {
        guard !deletions.isEmpty else {
            return
        }
        guard let db else {
            fatalError() // TODO
        }
        let timestamp = Date()
        let deletions: [MHCFHIRStoreDatabase.Deletion] = deletions.map { deletion in
            MHCFHIRStoreDatabase.Deletion(timestamp: timestamp, sampleType: sampleType.id, sampleId: deletion.uuid)
        }
        try await db.insert(deletions: deletions)
    }
}



@MHCFHIRStoreActor
final class MHCFHIRStoreDatabase: Sendable {
    private typealias UpdateHook = (
        _ operation: Connection.Operation,
        _ db: String,
        _ table: String,
        _ rowId: Int64
    ) -> Void
    
    nonisolated(unsafe) private let db: Connection
    
    private let samples = Table("samples")
    private let deletions = Table("deletions")
    
    //    /// The id (primary key) of this entry within the table.
    //    /// - Important: Not a HealthKit-assigned id!
    //    private let id = SQLite.Expression<UInt64>("id")
    
    /// When the app was informed about this record.
    private let timestamp = SQLite.Expression<Date>("timestamp")
    private let sampleType = SQLite.Expression<String>("sampleType")
    private let sampleId = SQLite.Expression<UUID>("sampleId")
    private let fhirJson = SQLite.Expression<String>("fhirJson")
    
    private var updateHooks: [UpdateHook] = []
    
    nonisolated init(url: URL) throws {
        print("TS", sqlite3_threadsafe())
        db = try Connection(.uri(url.absoluteURL.path(percentEncoded: false)))
        try db.run(deletions.create { table in
            // TODO primary key?
            table.column(timestamp)
            table.column(sampleType)
            table.column(sampleId)
        })
        try db.run(samples.create { table in
            // TODO primary key?
            table.column(timestamp)
            table.column(sampleType)
            table.column(sampleId)
            table.column(fhirJson)
        })
        
        db.updateHook { operation, db, table, rowId in
            for hook in self.updateHooks {
                hook(operation, db, table, rowId)
            }
        }
    }
}


extension MHCFHIRStoreDatabase {
    struct Sample: Sendable {
        let timestamp: Date
        let sampleType: String
        let sampleId: UUID
        let fhirJson: String
    }
    
    struct Deletion: Sendable {
        let timestamp: Date
        let sampleType: String
        let sampleId: UUID
    }
    
    
    @MHCFHIRStoreActor
    func insert(samples incomingSamples: some Collection<Sample>) throws {
        guard !incomingSamples.isEmpty else {
            return
        }
        try db.transaction {
            for sample in incomingSamples {
                try db.run(samples.insert(
                    timestamp <- sample.timestamp,
                    sampleType <- sample.sampleType,
                    sampleId <- sample.sampleId,
                    fhirJson <- sample.fhirJson
                ))
            }
        }
    }
    
    @MHCFHIRStoreActor
    func insert(deletions incomingDeletions: some Collection<Deletion>) throws {
        guard !incomingDeletions.isEmpty else {
            return
        }
        try db.transaction {
            for deletion in incomingDeletions {
                try db.run(deletions.insert(
                    timestamp <- deletion.timestamp,
                    sampleType <- deletion.sampleType,
                    sampleId <- deletion.sampleId
                ))
            }
        }
        
//        try db.transaction {
//            for deletion in deletions {
//                // try to delete any cached samples matching this deletion record
//                let didDelete = try db.run(
//                    samples.filter(sampleId == deletion.uuid && self.sampleType == sampleType.id).delete()
//                ) > 0
//                if didDelete {
//                    // if we managed to delete any matching samples, we also remove any pending deletions for this UUID & sampleType, if they exist
//                    try db.run(
//                        self.deletions.filter(sampleId == deletion.uuid && self.sampleType == sampleType.id).delete()
//                    )
//                } else {
//                    // otherwise, we record the deletion
//                    try db.run(self.deletions.insert(
//                        self.timestamp <- timestamp,
//                        self.sampleType <- sampleType.id,
//                        self.sampleId <- deletion.uuid,
//                    ))
//                }
//            }
//        }
    }
}
