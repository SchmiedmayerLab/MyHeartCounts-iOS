//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

// swiftlint:disable file_length

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
    private static let healthKit = HealthKit()
    
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
        staging.testing?.facts = try .testing(build: "100", operatingSystem: "26.0", studyRevision: 1)
        let first = try await staging.add(samples)
        let firstStaged = try staging.drainStagedSamples()

        staging.testing?.facts = try .testing(build: "110", operatingSystem: "27.0", studyRevision: 2)
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
        let exporter = try staging.healthKitExporter(accountDataGeneration: LocalPreferencesStore.standard[.accountDataGeneration])
        let graphs = try await exporter.deliver(samples)
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
            relaunched.testing?.stateStore = FHIRExchangeStateStore(
                accountDataGeneration: LocalPreferencesStore.standard[.accountDataGeneration],
                secretsSharedWith: identity
            )
            let receipt = try await relaunched.add(samples)
            #expect(try relaunched.drainStagedSamples() == beforeCrash)
            try await receipt.commitAnchor()
            #expect(try relaunched.ledger.reservationCount == 0)
        }
    }

    /// M7, live path: the delivery `handleNewSamples` stages keeps its reservations until the action Grove runs after
    /// the anchor commit, also when it spans several sample types.
    @Test
    func liveDeliveryHoldsItsEventsUntilTheAnchorCommits() async throws {
        let staging = try await HealthUploadStaging.resolvedForTesting()
        let ledger = try staging.ledger
        let samples: [HKSample] = [LedgerHarness.steps(0), LedgerHarness.steps(1), heartRateSample(2)]
        let action = try #require(try await MyHeartCountsStandard.stageNewSamples(
            samples,
            accountDataGeneration: LocalPreferencesStore.standard[.accountDataGeneration],
            through: .testing(staging: staging)
        ))
        #expect(Set(try staging.drainStagedSamples().keys) == Set(samples.map(\.uuid)))
        #expect(try ledger.reservationCount == 3)

        await action()
        #expect(try ledger.reservationCount == 0)
        // Running it again changes nothing.
        await action()
        #expect(try ledger.reservationCount == 0)
    }

    /// M7, live path: a delivery uploaded as one file, as HealthKit types MHC does not model are, keeps its
    /// reservations until the anchor commits; the file is the graphs' validated bytes spliced in sample order.
    @Test
    func liveUploadFileHoldsItsEventsUntilTheAnchorCommits() async throws {
        let staging = try await HealthUploadStaging.resolvedForTesting()
        let ledger = try staging.ledger
        let files = StagedUploadFiles()
        let accountDataGeneration = LocalPreferencesStore.standard[.accountDataGeneration]
        let samples = (0..<3).map(LedgerHarness.steps)
        let receipt = try await MyHeartCountsStandard.uploadHealthObservations(
            samples,
            accountDataGeneration: accountDataGeneration,
            uploadStrategy: .firebaseStorage,
            through: .testing(staging: staging, files: files)
        )
        #expect(try ledger.reservationCount == 3)
        #expect(try staging.drainStagedSamples().isEmpty)

        // Before the anchor commits, the same exporter reproduces the events the file carries.
        let graphs = try await staging.healthKitExporter(accountDataGeneration: accountDataGeneration).deliver(samples)
        let ordered = graphs.graphs.sorted { $0.key.uuidString.lowercased() < $1.key.uuidString.lowercased() }
        #expect(files.all == [splicedJSONArray(ordered.map(\.value))])
        graphs.receipt?.release()

        try await receipt.commitAnchor()
        #expect(try ledger.reservationCount == 0)
    }
}


// MARK: Live Delivery

extension HealthKitBatchExportTests {
    private struct StageFailure: Error {}

    private struct DeliveryUnavailable: Error {}

    /// M7, live path: `handleNewSamples` stages a delivery the account accepts and returns the action that releases
    /// its events once Grove has committed the anchor.
    @Test
    func acceptedDeliveryReturnsTheActionThatReleasesIt() async throws {
        let staging = try await HealthUploadStaging.resolvedForTesting()
        let ledger = try staging.ledger
        let samples: [HKSample] = [LedgerHarness.steps(0), heartRateSample(1)]

        let action = try #require(try await MyHeartCountsStandard.handleNewSamples(samples, through: .testing(staging: staging)))
        #expect(Set(try staging.drainStagedSamples().keys) == Set(samples.map(\.uuid)))
        #expect(try ledger.reservationCount == 2)

        await action()
        #expect(try ledger.reservationCount == 0)
    }

    /// A delivery the account consumes without staging (signed in, not enrolled) stages and reserves nothing, and one
    /// it cannot take yet throws, so Grove keeps the anchor.
    @Test
    func deliveryTheAccountDoesNotAcceptStagesNothing() async throws {
        let staging = try await HealthUploadStaging.resolvedForTesting()
        let ledger = try staging.ledger
        let samples: [HKSample] = [LedgerHarness.steps(0), heartRateSample(1)]

        let consumed = try await MyHeartCountsStandard.handleNewSamples(
            samples,
            through: .testing(staging: staging) { false }
        )
        #expect(consumed == nil)
        await #expect(throws: DeliveryUnavailable.self) {
            _ = try await MyHeartCountsStandard.handleNewSamples(
                samples,
                through: .testing(staging: staging) { throw DeliveryUnavailable() }
            )
        }
        #expect(try staging.drainStagedSamples().isEmpty)
        #expect(try ledger.reservationCount == 0)
    }

    /// A live upload file that fails to stage fails the delivery, so Grove keeps its anchor, and keeps the file's events
    /// reserved: the redelivery stages the same bytes.
    @Test
    func liveUploadFileThatFailsToStageKeepsItsEventsForTheRedelivery() async throws {
        let staging = try await HealthUploadStaging.resolvedForTesting()
        let ledger = try staging.ledger
        let accountDataGeneration = LocalPreferencesStore.standard[.accountDataGeneration]
        let samples = (0..<3).map(LedgerHarness.steps)
        let attempted = StagedUploadFiles()

        await #expect(throws: StageFailure.self) {
            _ = try await MyHeartCountsStandard.uploadHealthObservations(
                samples,
                accountDataGeneration: accountDataGeneration,
                uploadStrategy: .firebaseStorage,
                through: .testing(staging: staging) { file, _ in
                    try attempted.stage(file)
                    throw StageFailure()
                }
            )
        }
        #expect(attempted.all.count == 1)
        #expect(try ledger.reservationCount == 3)

        let files = StagedUploadFiles()
        let receipt = try await MyHeartCountsStandard.uploadHealthObservations(
            samples,
            accountDataGeneration: accountDataGeneration,
            uploadStrategy: .firebaseStorage,
            through: .testing(staging: staging, files: files)
        )
        #expect(files.all == attempted.all)
        #expect(try ledger.producerEntry().next == "4", "the redelivery reused every event of the failed attempt")
        try await receipt.commitAnchor()
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
        var entries: [PreparedHealthObservationFHIRPayload.Entry] = []
        var exporterBuilds = 0
        let export = try await QuantitySample.export(
            [lipids],
            at: LedgerHarness.start,
            recordProvider: .healthKit(Self.healthKit),
            exporter: { () throws -> HealthKitFHIRExporter in
                exporterBuilds += 1
                return try LedgerHarness(ledger: .forTesting()).exporter()
            }()
        ) { entry in
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
    private struct FetchFailure: Error {}

    /// A fetched record's sample, observed without keeping it alive.
    private final class FetchedRecord {
        weak var sample: HKSample?

        init(_ sample: HKSample) {
            self.sample = sample
        }
    }

    /// What a stand-in record holds: an ECG of 30 s at 512 Hz. HealthKit vends ECGs only from its store, and
    /// voltage measurements only from an ECG, so each stand-in sample states an ECG's count.
    private static let measurementsPerECG = 15_360

    /// Records whose samples each state an ECG's measurement count; fetching `failing` throws.
    private static func ecgStandInsRecordProvider(failingAt failing: UUID? = nil) -> HealthKitFHIRExporter.RecordProvider {
        ._custom(
            getNumVoltages: { _ in measurementsPerECG },
            getRecord: { sample in
                if sample.uuid == failing {
                    throw FetchFailure()
                }
                return .sample(sample)
            }
        )
    }

    /// Each HealthKit entry carries its graph's validated bytes, never a re-encoding of the graph's bundle.
    @Test
    func healthKitEntriesCarryTheirGraphsBytes() async throws {
        let exporter = try LedgerHarness(ledger: .forTesting()).exporter()
        let samples: [HKSample] = [LedgerHarness.steps(0), heartRateSample(1), Self.symptom]
        var entries: [PreparedHealthObservationFHIRPayload.Entry] = []
        let export = try await exporter.exportBatch(samples, at: LedgerHarness.start, recordProvider: .healthKit(Self.healthKit)) { entry in
            entries.append(entry)
        }

        let graphs = try await exporter.deliver(samples)
        #expect(entries.map(\.sourceID) == samples.map(\.uuid))
        for entry in entries {
            guard case .graph(let json) = entry.content else {
                Issue.record("A HealthKit sample is uploaded as its graph's bytes")
                continue
            }
            #expect(json == graphs.graphs[entry.sourceID])
        }
        graphs.receipt?.release()
        export.receipt.completeAfterSourceAcknowledgement()
    }

    /// A batch counts its graphs' warnings by kind across every exporter call, each sample once, so it logs them once.
    @Test
    func batchReportsItsWarningsOncePerSampleAcrossCalls() async throws {
        let exporter = try LedgerHarness(ledger: .forTesting()).exporter()
        // Five calls of eight; no step count names a time zone, so each states both ends of its Period in UTC.
        let export = try await exporter.exportBatch(
            (0..<40).map(LedgerHarness.steps),
            at: LedgerHarness.start,
            recordProvider: Self.ecgStandInsRecordProvider(),
            receive: { _ in }
        )
        let kinds = export.warnings.kinds
        #expect(kinds.map(\.code) == [ExchangeGraphRule.mobileOmissionSourceOffset.rawValue])
        #expect(kinds.first?.sampleCountByType == [HKQuantityTypeIdentifier.stepCount.rawValue: 40])
        #expect(kinds.first?.locations == ["Observation.effectivePeriod.start", "Observation.effectivePeriod.end"])
        export.receipt.completeAfterSourceAcknowledgement()

        let zoned = HKQuantitySample(
            type: HKQuantityType(.stepCount),
            quantity: HKQuantity(unit: .count(), doubleValue: 12),
            start: LedgerHarness.start,
            end: LedgerHarness.start.addingTimeInterval(30),
            metadata: [HKMetadataKeyTimeZone: "Europe/Berlin"]
        )
        let clean = try await exporter.exportBatch([zoned], at: LedgerHarness.start, recordProvider: .healthKit(Self.healthKit)) { _ in }
        #expect(clean.warnings.isEmpty)
        clean.receipt.completeAfterSourceAcknowledgement()
    }

    /// M16: a batch of 40 ECGs is exported in calls of at most ``HealthKitFHIRExporter/voltageBudget`` voltage
    /// measurements, never keeps more fetched records alive than that, and releases every call's reservations; a
    /// batch without ECGs is one call.
    @Test
    func ecgBatchNeverHoldsMoreThanTheVoltageBudget() async throws {
        let ledger = FHIRExchangeLedger.forTesting()
        let exporter = try LedgerHarness(ledger: ledger).exporter()
        let counter = try ledger.countingTransactions()
        // Each fetch returns a fresh record, as an ECG's fetched voltages are, so only the export keeps it alive.
        var fetched: [FetchedRecord] = []
        var mostHeld = 0
        let recordProvider: HealthKitFHIRExporter.RecordProvider = ._custom(
            getNumVoltages: { _ in Self.measurementsPerECG },
            getRecord: { sample in
                let quantitySample = try #require(sample as? HKQuantitySample)
                let record = autoreleasepool {
                    HKQuantitySample(
                        type: quantitySample.quantityType,
                        quantity: quantitySample.quantity,
                        start: quantitySample.startDate,
                        end: quantitySample.endDate
                    )
                }
                let alive = fetched.count { $0.sample != nil }
                mostHeld = max(mostHeld, (alive + 1) * Self.measurementsPerECG)
                fetched.append(FetchedRecord(record))
                return .sample(record)
            }
        )

        var delivered = 0
        let export = try await exporter.exportBatch(
            (0..<40).map(LedgerHarness.steps),
            at: LedgerHarness.start,
            recordProvider: recordProvider
        ) { _ in
            delivered += 1
        }

        #expect(delivered == 40)
        #expect(mostHeld == HealthKitFHIRExporter.voltageBudget)
        let calls = 40 * Self.measurementsPerECG / HealthKitFHIRExporter.voltageBudget
        #expect(counter.transactions == calls)
        #expect(try ledger.reservationCount == 40)
        // Completing the batch releases every call's reservations, one transaction each.
        export.receipt.completeAfterSourceAcknowledgement()
        #expect(counter.transactions == 2 * calls)
        #expect(try ledger.reservationCount == 0)

        let callsBefore = counter.transactions
        _ = try await exporter.exportBatch(
            (40..<140).map(LedgerHarness.steps),
            at: LedgerHarness.start,
            recordProvider: .healthKit(Self.healthKit)
        ) { _ in }
        #expect(counter.transactions == callsBefore + 1)
    }

    /// A batch that fails after some of its calls completed drops their receipts, so their holds lapse: the redelivery
    /// stages the same events and bytes for them, and completing it releases the whole batch.
    @Test
    func batchFailingAfterEarlierCallsIsRedeliveredExactly() async throws {
        let ledger = FHIRExchangeLedger.forTesting()
        let exporter = try LedgerHarness(ledger: ledger).exporter()
        let samples = (0..<40).map(LedgerHarness.steps)

        var firstAttempt: [UUID: Data] = [:]
        do {
            _ = try await exporter.exportBatch(
                samples,
                at: LedgerHarness.start,
                recordProvider: Self.ecgStandInsRecordProvider(failingAt: samples[30].uuid)
            ) { entry in
                firstAttempt[entry.sourceID] = try entry.json()
            }
            Issue.record("A failing fetch ends the batch")
        } catch is FetchFailure {}
        // Three calls of eight completed before the fourth call's records were fetched.
        #expect(Set(firstAttempt.keys) == Set(samples.prefix(24).map(\.uuid)))
        #expect(try ledger.reservationCount == 24)

        var redelivery: [UUID: Data] = [:]
        let export = try await exporter.exportBatch(
            samples,
            at: LedgerHarness.start,
            recordProvider: Self.ecgStandInsRecordProvider()
        ) { entry in
            redelivery[entry.sourceID] = try entry.json()
        }
        #expect(redelivery.count == 40)
        for (sample, json) in firstAttempt {
            #expect(redelivery[sample] == json)
        }
        #expect(try ledger.producerEntry().next == "41", "the redelivery reused every event of the failed attempt")
        export.receipt.completeAfterSourceAcknowledgement()
        #expect(try ledger.reservationCount == 0)
    }
}
