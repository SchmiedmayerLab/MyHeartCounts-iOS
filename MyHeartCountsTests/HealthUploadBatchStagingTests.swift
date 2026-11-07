//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFHIRContract
import GroveFoundation
import HealthKit
@testable import MyHeartCounts
import Testing


/// A batch of records fresh from an exporter, as the historical and the `.firebaseStorage` paths upload it.
@Suite
struct HealthUploadBatchStagingTests {
    private static let stepCount = HKQuantityTypeIdentifier.stepCount.rawValue

    /// The records of `count` samples, in sample order.
    private static func records(count: Int, subject: FHIRExchangeSubject? = nil) async throws -> [ExchangeRecord] {
        let samples = (0..<count).map(ExchangeHarness.steps)
        let delivery = try await ExchangeHarness().exporter(subject: subject).deliver(samples)
        return try samples.map { try #require(delivery.records[$0.uuid]) }
    }

    /// One exporter can't state two subjects, and an upload must not mix them: such a batch stages nothing.
    @Test
    func aRecordOfAnotherSubjectFailsTheBatchBeforeItStages() async throws {
        let records = try await Self.records(count: 1) + Self.records(count: 1, subject: try ExchangeHarness.otherSubject)
        let files = StagedUploadFiles()

        await #expect(throws: HealthUploadBatch.PackingError.self) {
            try await HealthUploadBatch.stage(
                records,
                sampleType: Self.stepCount,
                packedAt: ExchangeHarness.start,
                stage: { try files.stage($0) }
            )
        }

        #expect(files.all.isEmpty)
    }

    /// Under one instant a live upload's redelivery is an exact retry: every byte and the name repeat. Another instant states
    /// new versions of the same source records.
    @Test
    func liveUploadFileRepeatsEveryByteOnlyUnderOneInstant() async throws {
        let staging = try await HealthUploadStaging.resolvedForTesting()
        let accountDataGeneration = LocalPreferencesStore.standard[.accountDataGeneration]
        let samples = (0..<3).map(ExchangeHarness.steps)
        func deliver(at instant: Date, to files: StagedUploadFiles) async throws {
            var dependencies = MyHeartCountsStandard.HealthObservationUploadDependencies.testing(staging: staging, files: files)
            dependencies.now = { instant }
            try await MyHeartCountsStandard.uploadHealthObservations(
                samples,
                accountDataGeneration: accountDataGeneration,
                uploadStrategy: .firebaseStorage,
                through: dependencies
            )
        }

        let first = StagedUploadFiles()
        let retry = StagedUploadFiles()
        let later = StagedUploadFiles()
        try await deliver(at: ExchangeHarness.start, to: first)
        try await deliver(at: ExchangeHarness.start, to: retry)
        try await deliver(at: ExchangeHarness.start.addingTimeInterval(60), to: later)

        #expect(retry.all == first.all)
        #expect(retry.names == first.names)
        #expect(later.names != first.names)
        #expect(try later.records.map(\.sourceRecord) == first.records.map(\.sourceRecord))
        #expect(Set(try later.records.map(\.version)).isDisjoint(with: try first.records.map(\.version)))
    }
}
