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
import GRDB
import Spezi
import Observation
import SpeziHealthKit
import MyHeartCountsShared


@Observable
final class MHCFHIRStore: Spezi::Module, EnvironmentAccessible, @unchecked Sendable {
    @ObservationIgnored @Application(\.logger) private var logger
    @ObservationIgnored @Dependency(HealthKit.self) private var healthKit
    @ObservationIgnored let db: MHCFHIRStoreDatabase?
    @ObservationIgnored private let jsonEncoder = JSONEncoder()
    
    nonisolated init() {
        do {
            let url = URL.documentsDirectory.appendingPathComponent("healthObservations.sqlite3")
            db = try! MHCFHIRStoreDatabase(url: url)
        } catch {
            print("Error creating db: \(error)")
            db = nil
        }
        jsonEncoder.outputFormatting = [.withoutEscapingSlashes]
    }
    
    
    func clear() throws {
        try db?.clear()
    }
}


// MARK: Insertion

extension MHCFHIRStore {
    func add<Sample>(_ samples: some Collection<Sample> & Sendable, ofType sampleType: SampleType<Sample>) async throws {
        try await add(samples, commonSampleType: sampleType.id)
    }
    
    func add(
        _ samples: consuming some Collection<some HealthObservation> & Sendable,
        commonSampleType: String? = nil,
        postprocessResource: @Sendable (FHIRResource) throws -> Void = { _ in }
    ) async throws {
        guard !samples.isEmpty else {
            return
        }
        guard let db else {
            fatalError() // TODO
        }
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
                id: UUID(),
                timestamp: timestamp,
                sampleType: sampleType,
                sampleId: sampleId,
                fhirJson: String(decoding: consume fhirJson, as: UTF8.self)
            ))
        }
        let numSamples = fhirSamples.count
        logger.notice("Adding samples (N=\(numSamples)) to the db")
        try db.insert(samples: fhirSamples)
    }
    
    func add<Sample>(_ deletions: some Collection<HKDeletedObject> & Sendable, ofType sampleType: SampleType<Sample>) throws {
        guard !deletions.isEmpty else {
            return
        }
        guard let db else {
            fatalError() // TODO
        }
        let timestamp = Date()
        let deletions: [MHCFHIRStoreDatabase.Deletion] = deletions.map { deletion in
            MHCFHIRStoreDatabase.Deletion(
                id: UUID(),
                timestamp: timestamp,
                sampleType: sampleType.id,
                sampleId: deletion.uuid
            )
        }
        let numDeletions = deletions.count
        logger.notice("Adding deletions (N=\(numDeletions)) to the db")
        try db.insert(deletions: deletions)
    }
}
