//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GRDB
import Grove
import GroveFHIRContract
import GroveFoundation
import GroveHealthKit
import GroveHealthKitFHIR
import GroveTesting
import HealthKit
@testable import MyHeartCounts
import Testing


/// The holder's fence, and what staging does with it: `forTesting` staging answers these lookups itself, so these tests stage
/// as production does, through a holder they set directly.
@Suite
struct HealthKitExporterHolderTests {
    /// Staging as production builds it, over `holder`: without testing overrides, every exporter and subject is the holder's.
    private static func productionStaging(over holder: HealthKitExporterHolder) async -> HealthUploadStaging {
        let staging = HealthUploadStaging(persistence: .inMemory)
        await withDependencyResolution(standard: BatchExportTestStandard()) {
            holder
            staging
            HealthKit()
        }
        return staging
    }

    /// What the holder states while `subject` is signed in.
    private static func current(of subject: FHIRExchangeSubject) throws -> HealthKitExporterHolder.Current {
        HealthKitExporterHolder.Current(exporter: try ExchangeHarness().exporter(subject: subject), subject: subject)
    }

    /// One deletion, as the anchored query reports it.
    private static func deleteSample(in staging: HealthUploadStaging) throws {
        try staging.add([try HKDeletedObject.make(uuid: UUID())], ofType: .stepCount, deletedAfter: nil)
    }

    private static func generation() -> Int {
        LocalPreferencesStore.standard[.accountDataGeneration]
    }

    /// Drains every staged deletion under `subject`, which may leave only through `stage`, returning how often it did.
    @discardableResult
    private static func drainDeletions(
        from staging: HealthUploadStaging,
        subject: FHIRExchangeSubject
    ) async throws -> Int {
        var staged = 0
        _ = try await HealthUploadStagingUploader.drainPendingDeletions(
            from: staging,
            before: .distantFuture,
            maximumChunks: nil,
            subject: subject,
            stage: { _ in
                staged += 1
            },
            stageUnreadable: { url in
                Issue.record("A valid retraction left as \(url.lastPathComponent)")
            },
            integrityEvents: { event in
                Issue.record("A healthy chunk reported \(event.kind.rawValue)")
            }
        )
        return staged
    }

    /// While no account's exporter is built, a batch has none to export through, also once one was cleared.
    @Test
    func holderWithoutAnExporterIsUnavailable() throws {
        let holder = HealthKitExporterHolder()
        #expect(throws: FHIRExchangeStateError.healthKitExporterUnavailable) {
            _ = try holder.current(forBatchOf: 0)
        }

        holder.set(try Self.current(of: ExchangeHarness.subject), accountDataGeneration: 0)
        _ = try holder.current(forBatchOf: 0)
        holder.set(nil, accountDataGeneration: 0)
        #expect(throws: FHIRExchangeStateError.healthKitExporterUnavailable) {
            _ = try holder.healthKitExporter(forBatchOf: 0)
        }
    }

    /// A batch captured under another generation never exports through the exporter of this one, earlier or later.
    @Test
    func holderRefusesABatchOfAnotherGeneration() throws {
        let holder = HealthKitExporterHolder()
        let subject = try ExchangeHarness.subject
        holder.set(try Self.current(of: subject), accountDataGeneration: 3)

        #expect(try holder.current(forBatchOf: 3).subject.isNamed(by: subject.identity))
        for captured in [2, 4] {
            #expect(throws: FHIRExchangeStateError.staleAccountGeneration(captured: captured, current: 3)) {
                _ = try holder.current(forBatchOf: captured)
            }
            #expect(throws: FHIRExchangeStateError.staleAccountGeneration(captured: captured, current: 3)) {
                _ = try holder.healthKitExporter(forBatchOf: captured)
            }
        }
    }

    /// Without an exporter a delivery stages nothing and throws, which keeps its anchor, so it is delivered again.
    @Test
    func deliveryWithoutAnExporterStagesNothing() async throws {
        let staging = await Self.productionStaging(over: HealthKitExporterHolder())

        #expect(throws: FHIRExchangeStateError.healthKitExporterUnavailable) {
            try Self.deleteSample(in: staging)
        }
        await #expect(throws: FHIRExchangeStateError.healthKitExporterUnavailable) {
            try await staging.add([ExchangeHarness.steps(0)])
        }
        #expect(try staging.isEmpty)
    }

    /// An exporter of another generation is refused for each thing staging asks of it.
    @Test
    func stagingRefusesAnExporterOfAnotherGeneration() async throws {
        let holder = HealthKitExporterHolder()
        let staging = await Self.productionStaging(over: holder)
        let subject = try ExchangeHarness.subject
        let generation = Self.generation()
        holder.set(try Self.current(of: subject), accountDataGeneration: generation + 1)
        let stale = FHIRExchangeStateError.staleAccountGeneration(captured: generation, current: generation + 1)

        #expect(throws: stale) {
            try Self.deleteSample(in: staging)
        }
        await #expect(throws: stale) {
            try await staging.add([ExchangeHarness.steps(0)])
        }
        await #expect(throws: stale) {
            _ = try await staging.retractionExporter(subject: subject, accountDataGeneration: generation)
        }
        #expect(try staging.isEmpty)
    }

    /// Every row stores the subject the holder's exporter was built for.
    @Test
    func rowsStoreTheHoldersSubject() async throws {
        let holder = HealthKitExporterHolder()
        let staging = await Self.productionStaging(over: holder)
        let subject = try ExchangeHarness.subject
        holder.set(try Self.current(of: subject), accountDataGeneration: Self.generation())

        try await staging.add([ExchangeHarness.steps(0)])
        try Self.deleteSample(in: staging)

        let (samples, deletions) = try staging.writeForTesting { db in
            (try HealthUploadStaging.PendingSampleRecord.fetchAll(db), try HealthUploadStaging.PendingDeletionRecord.fetchAll(db))
        }
        #expect(samples.map(\.subjectSystem) == [subject.identity.system.rawValue])
        #expect(samples.map(\.subjectValue) == [subject.identity.value])
        #expect(deletions.map(\.subjectSystem) == [subject.identity.system.rawValue])
        #expect(deletions.map(\.subjectValue) == [subject.identity.value])
    }

    /// The holder's exporter retracts only for the subject it was built for.
    @Test
    func retractionExporterIsTheHoldersOwnSubjects() async throws {
        let holder = HealthKitExporterHolder()
        let staging = await Self.productionStaging(over: holder)
        let subject = try ExchangeHarness.subject
        let generation = Self.generation()
        holder.set(try Self.current(of: subject), accountDataGeneration: generation)

        _ = try await staging.retractionExporter(subject: subject, accountDataGeneration: generation)
        await #expect(throws: FHIRExchangeDestinationError.accountChanged) {
            _ = try await staging.retractionExporter(subject: ExchangeHarness.otherSubject, accountDataGeneration: generation)
        }
    }

    /// An account that changes mid-drain is transient: the drain fails and leaves the chunk, stages nothing, and the next drain
    /// under the account retracts it.
    @Test
    func accountChangeMidDrainLeavesTheChunkForTheNextDrain() async throws {
        let holder = HealthKitExporterHolder()
        let staging = await Self.productionStaging(over: holder)
        let subject = try ExchangeHarness.subject
        let generation = Self.generation()
        holder.set(try Self.current(of: subject), accountDataGeneration: generation)
        try Self.deleteSample(in: staging)

        holder.set(try Self.current(of: ExchangeHarness.otherSubject), accountDataGeneration: generation)
        await #expect(throws: FHIRExchangeDestinationError.accountChanged) {
            try await Self.drainDeletions(from: staging, subject: subject)
        }
        #expect(try staging.fetchCount(of: HealthUploadStaging.PendingDeletionRecord.self) == 1)

        holder.set(try Self.current(of: subject), accountDataGeneration: generation)
        #expect(try await Self.drainDeletions(from: staging, subject: subject) == 1)
        #expect(try staging.isEmpty)
    }
}
