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
@testable import GroveHealthKit
import GroveHealthKitFHIR
import HealthKit
@testable import MyHeartCounts
import MyHeartCountsShared
import Synchronization
import Testing


/// The live path stages a whole HealthKit delivery through one exporter call, and holds the delivery's events until
/// the HealthKit anchor is committed: until then, a redelivery reproduces every staged byte.
@Suite
struct HealthKitBatchExportTests {
    /// Mild chest tightness, an ECG symptom exported on its own.
    private static var symptom: HKCategorySample {
        HKCategorySample(
            type: HKCategoryType(.chestTightnessOrPain),
            value: HKCategoryValueSeverity.mild.rawValue,
            start: LedgerHarness.start,
            end: LedgerHarness.start.addingTimeInterval(60)
        )
    }

    /// Delivers `samples` and ends the process before the anchor commits: the receipt is dropped unreleased and the
    /// ledger closed. Returns the identity the delivery was exported under and what it staged.
    private static func deliverAndCrash(
        _ samples: [HKSample],
        root: URL,
        binding: InMemoryDeviceBinding
    ) async throws -> (identity: FHIRExchangeStateStore, staged: [UUID: Data]) {
        let staging = try await HealthUploadStaging.resolvedForTesting(ledger: .liveFencedInDirectory(root, binding: binding))
        _ = try await staging.add(samples)
        let staged = try staging.drainStagedSamples()
        try staging.ledger.closeForTesting()
        return (try staging.stateStore, staged)
    }

    /// M3: the app build, the OS version and the study revision change between a delivery and its redelivery, yet
    /// every staged byte is the same until the anchor commits; then the next delivery is a new event.
    @Test
    func redeliveryBeforeTheAnchorCommitsStagesTheSameBytes() async throws {
        let staging = try await HealthUploadStaging.resolvedForTesting()
        let samples: [HKSample] = [LedgerHarness.steps(0), heartRateSample(1), Self.symptom]
        staging.testingFacts = try .testing(build: "100", operatingSystem: "26.0", studyRevision: 1)
        let first = try await staging.add(samples)
        let firstStaged = try staging.drainStagedSamples()

        staging.testingFacts = try .testing(build: "110", operatingSystem: "27.0", studyRevision: 2)
        let redelivery = try await staging.add(samples)
        let redeliveryStaged = try staging.drainStagedSamples()

        #expect(Set(firstStaged.keys) == Set(samples.map(\.uuid)))
        #expect(redeliveryStaged == firstStaged)

        try await first.commitAnchor()
        try await redelivery.commitAnchor()
        _ = try await staging.add(samples)
        let nextStaged = try staging.drainStagedSamples()
        for sample in samples {
            let staged = try #require(firstStaged[sample.uuid])
            let next = try #require(nextStaged[sample.uuid])
            #expect(try stagedEvent(next) != stagedEvent(staged))
            #expect(try stagedDeviceVersions(staged).isSuperset(of: ["100", "26.0"]))
            #expect(try stagedDeviceVersions(next).isSuperset(of: ["110", "27.0"]))
        }
    }

    /// M4: a delivery of 1 000 samples reserves in one ledger transaction and releases in one more.
    @Test
    func thousandSamplesCostOneReserveAndOneRelease() async throws {
        let staging = try await HealthUploadStaging.resolvedForTesting()
        let ledger = try staging.ledger
        let counter = try ledger.countingTransactions()

        let receipt = try await staging.add((0..<1000).map(LedgerHarness.steps))
        #expect(counter.transactions == 1)
        #expect(try ledger.reservationCount == 1000)
        #expect(try staging.fetchCount(of: HealthUploadStaging.PendingSampleRecord.self) == 1000)

        try await receipt.commitAnchor()
        #expect(counter.transactions == 2)
        #expect(try ledger.reservationCount == 0)
    }

    /// M4: staging stores each graph's validated bytes, as the exporter staging builds produces them.
    @Test
    func stagedBytesAreTheGraphsJSON() async throws {
        let staging = try await HealthUploadStaging.resolvedForTesting()
        let samples: [HKSample] = [LedgerHarness.steps(0), LedgerHarness.steps(1), heartRateSample(2)]
        let receipt = try await staging.add(samples)
        let staged = try staging.drainStagedSamples()

        // Before the anchor commits, the same exporter reproduces the events staging reserved.
        let exporter = try await staging.healthKitExporter(accountDataGeneration: LocalPreferencesStore.standard[.accountDataGeneration])
        let graphs = try exporter.deliver(samples)
        #expect(staged == graphs.graphs)
        graphs.receipt?.release()
        try await receipt.commitAnchor()
    }

    /// M5: a crash between the reservation and the anchor commit leaves the receipt unreleased; the redelivery in
    /// the next process stages the same events and bytes.
    @Test
    func redeliveryAfterACrashStagesTheSameBytes() async throws {
        try await withTemporaryRoot { root in
            let samples: [HKSample] = [LedgerHarness.steps(0), heartRateSample(1)]
            let binding = InMemoryDeviceBinding()
            let (identity, beforeCrash) = try await Self.deliverAndCrash(samples, root: root, binding: binding)

            let relaunched = try await HealthUploadStaging.resolvedForTesting(ledger: .liveFencedInDirectory(root, binding: binding))
            relaunched.testingStateStore = FHIRExchangeStateStore(
                accountDataGeneration: LocalPreferencesStore.standard[.accountDataGeneration],
                secretsSharedWith: identity
            )
            let receipt = try await relaunched.add(samples)
            #expect(try relaunched.drainStagedSamples() == beforeCrash)
            try await receipt.commitAnchor()
            #expect(try relaunched.ledger.reservationCount == 0)
        }
    }

    /// M7, live path: the delivery's reservations stay until the action Grove runs after the anchor commit.
    @Test
    func liveDeliveryHoldsItsEventsUntilTheAnchorCommits() async throws {
        let staging = try await HealthUploadStaging.resolvedForTesting()
        let ledger = try staging.ledger
        let receipt = try await staging.add([LedgerHarness.steps(0), LedgerHarness.steps(1)])
        #expect(try ledger.reservationCount == 2)

        let action = try #require(receipt.anchorCommitAction)
        #expect(try ledger.reservationCount == 2)
        await action()
        #expect(try ledger.reservationCount == 0)
        // Completing it again, as a copy of the receipt would, changes nothing.
        receipt.completeAfterSourceAcknowledgement()
        #expect(try ledger.reservationCount == 0)
    }
}


extension HealthKitBatchExportTests {
    /// M10: an observation the app models itself needs no exporter, so staging it never opens the ledger, runs no
    /// ledger transaction, reads no identity secret and reserves nothing.
    @Test
    func selfModelledObservationNeverTouchesTheExporter() async throws {
        try await withTemporaryRoot { root in
            let ledger = FHIRExchangeLedger.liveFencedInDirectory(root)
            let staging = try await HealthUploadStaging.resolvedForTesting(ledger: ledger)
            let lipids = QuantitySample(
                id: UUID(),
                sampleType: .custom(.bloodLipids),
                unit: QuantitySample.SampleType.custom(.bloodLipids).displayUnit,
                value: 50,
                startDate: LedgerHarness.start,
                endDate: LedgerHarness.start
            )

            let receipt = try await staging.add([lipids])

            #expect(receipt.isEmpty)
            #expect(Set(try staging.drainStagedSamples().keys) == [lipids.id])
            let directory = try #require(ledger.directory)
            #expect(!FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)))
            #expect(!FileManager.default.fileExists(atPath: FHIRExchangeLedger.lockFile(for: directory).path(percentEncoded: false)))
            guard case .memory(let secrets) = try staging.stateStore.secrets else {
                Issue.record("Staging under test keeps its identity secret in memory")
                return
            }
            #expect(secrets.secret.withLock { $0 } == nil)
        }
    }

    /// M10: the conversion every upload strategy shares builds no exporter for self-modelled observations.
    @Test
    func batchOfSelfModelledObservationsBuildsNoExporter() async throws {
        let lipids = QuantitySample(
            id: UUID(),
            sampleType: .custom(.bloodLipids),
            unit: QuantitySample.SampleType.custom(.bloodLipids).displayUnit,
            value: 50,
            startDate: LedgerHarness.start,
            endDate: LedgerHarness.start
        )
        let batch = try HealthObservationBatch([lipids])
        var entries: [PreparedHealthObservationFHIRPayload.Entry] = []
        var exporterBuilds = 0
        let export = try await batch.export(at: LedgerHarness.start, using: HealthKit()) {
            exporterBuilds += 1
            return try LedgerHarness(ledger: .forTesting()).exporter()
        } receive: { entry in
            entries.append(entry)
        }

        #expect(exporterBuilds == 0)
        #expect(export.receipt.isEmpty)
        #expect(entries.map(\.sourceID) == [lipids.id])
        guard case .resource = entries.first?.content else {
            Issue.record("A self-modelled observation is uploaded as the resource it models")
            return
        }
    }
}


extension HealthKitBatchExportTests {
    /// M16: a batch of 40 ECGs is exported in calls of at most ``HealthKitFHIRExporter/voltageBudget`` voltage
    /// measurements, and never holds more fetched voltages than that; a batch without ECGs is one call.
    @Test
    func ecgBatchNeverHoldsMoreThanTheVoltageBudget() async throws {
        let ledger = FHIRExchangeLedger.forTesting()
        let exporter = try LedgerHarness(ledger: ledger).exporter()
        let counter = try ledger.countingTransactions()
        // 30 s at 512 Hz. HealthKit vends ECGs only from its store, so each stand-in sample states an ECG's count
        // and the counting fetch "loads" that many measurements.
        let measurementsPerECG = 15_360
        var held: [UUID: Int] = [:]
        var mostHeld = 0
        let records = HealthObservationRecords { _ in
            measurementsPerECG
        } record: { sample in
            held[sample.uuid] = measurementsPerECG
            mostHeld = max(mostHeld, held.values.reduce(0, +))
            return .sample(sample)
        }

        var delivered = 0
        _ = try await exporter.exportBatch((0..<40).map(LedgerHarness.steps), at: LedgerHarness.start, records: records) { entry in
            // A delivered record's voltages are dropped with its call.
            held[entry.sourceID] = nil
            delivered += 1
        }

        #expect(delivered == 40)
        #expect(mostHeld == HealthKitFHIRExporter.voltageBudget)
        #expect(counter.transactions == 40 * measurementsPerECG / HealthKitFHIRExporter.voltageBudget)

        let callsBefore = counter.transactions
        _ = try await exporter.exportBatch((40..<140).map(LedgerHarness.steps), at: LedgerHarness.start, using: HealthKit()) { _ in }
        #expect(counter.transactions == callsBefore + 1)
    }
}
