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
import ModelsR4
@testable import MyHeartCounts
import MyHeartCountsShared
import Testing


/// The live path stages a whole HealthKit delivery through one exporter call, and keeps nothing about it but the identity
/// secret: a redelivery is converted again, which repeats every source record, and repeats every staged byte only at the
/// same instant under the same facts.
@Suite
struct HealthKitBatchExportTests {
    private static let healthKit = HealthKit()
    
    /// Mild chest tightness, an ECG symptom exported on its own.
    private static var symptom: HKCategorySample {
        HKCategorySample(
            type: HKCategoryType(.chestTightnessOrPain),
            value: HKCategoryValueSeverity.mild.rawValue,
            start: ExchangeHarness.start,
            end: ExchangeHarness.start.addingTimeInterval(60)
        )
    }

    /// M3: a redelivery at the same instant under the same facts is an exact retry: it stages every byte again.
    @Test
    func redeliveryUnderTheSameFactsStagesTheSameBytes() async throws {
        let staging = try await HealthUploadStaging.resolvedForTesting()
        let samples: [HKSample] = [ExchangeHarness.steps(0), heartRateSample(1), Self.symptom]
        try await staging.add(samples, ingestionTimestamp: ExchangeHarness.start)
        let firstStaged = try staging.drainStagedSamples()

        try await staging.add(samples, ingestionTimestamp: ExchangeHarness.start)
        let redeliveryStaged = try staging.drainStagedSamples()

        #expect(Set(firstStaged.keys) == Set(samples.map(\.uuid)))
        #expect(redeliveryStaged == firstStaged)
    }

    /// M3: a redelivery states the app build, the OS version and the study revision as they stand, so when they changed,
    /// each sample is a new version of the same source record.
    @Test
    func redeliveryUnderNewFactsIsANewVersionOfTheSameSourceRecords() async throws {
        let staging = try await HealthUploadStaging.resolvedForTesting()
        let samples: [HKSample] = [ExchangeHarness.steps(0), heartRateSample(1), Self.symptom]
        staging.testing?.facts = try .testing(build: "100", operatingSystem: "26.0", studyRevision: 1)
        try await staging.add(samples, ingestionTimestamp: ExchangeHarness.start)
        let firstStaged = try staging.drainStagedSamples()

        staging.testing?.facts = try .testing(build: "110", operatingSystem: "27.0", studyRevision: 2)
        try await staging.add(samples, ingestionTimestamp: ExchangeHarness.start)
        let nextStaged = try staging.drainStagedSamples()

        for sample in samples {
            let staged = try #require(firstStaged[sample.uuid])
            let next = try #require(nextStaged[sample.uuid])
            #expect(try ExchangeRecord(validating: next).sourceRecord == ExchangeRecord(validating: staged).sourceRecord)
            #expect(try stagedRecordVersion(next) != stagedRecordVersion(staged))
            #expect(try stagedDeviceVersions(staged).isSuperset(of: ["100", "26.0"]))
            #expect(try stagedDeviceVersions(next).isSuperset(of: ["110", "27.0"]))
        }
    }

    /// M4: a delivery of 1 000 samples stages a row per sample, across several database writes.
    @Test
    func thousandSamplesStageARowEach() async throws {
        let staging = try await HealthUploadStaging.resolvedForTesting()
        try await staging.add((0..<1000).map(ExchangeHarness.steps))
        #expect(try staging.fetchCount(of: HealthUploadStaging.PendingSampleRecord.self) == 1000)
    }

    /// M4: staging stores each record's validated bytes, as the exporter staging builds produces them.
    @Test
    func stagedBytesAreTheRecordsJSON() async throws {
        let staging = try await HealthUploadStaging.resolvedForTesting()
        let samples: [HKSample] = [ExchangeHarness.steps(0), ExchangeHarness.steps(1), heartRateSample(2)]
        try await staging.add(samples, ingestionTimestamp: ExchangeHarness.start)
        let staged = try staging.drainStagedSamples()

        // At the instant staging converted at, the same exporter reproduces every record.
        let exporter = try await staging.healthKitExporter(accountDataGeneration: LocalPreferencesStore.standard[.accountDataGeneration])
        let delivery = try await exporter.deliver(samples)
        #expect(staged == delivery.graphs)
    }

    /// M5: a redelivery needs nothing a crash loses. In the next process, which keeps only the identity secret, the samples
    /// convert to the same bytes at the same instant, and to new versions of the same source records at a later one.
    @Test
    func redeliveryAfterACrashNeedsOnlyTheIdentitySecret() async throws {
        let samples: [HKSample] = [ExchangeHarness.steps(0), heartRateSample(1)]
        let crashed = try await HealthUploadStaging.resolvedForTesting()
        try await crashed.add(samples, ingestionTimestamp: ExchangeHarness.start)
        let beforeCrash = try crashed.drainStagedSamples()

        let relaunched = try await HealthUploadStaging.resolvedForTesting()
        relaunched.testing?.stateStore = FHIRExchangeStateStore(
            accountDataGeneration: LocalPreferencesStore.standard[.accountDataGeneration],
            secretsSharedWith: try crashed.stateStore
        )
        try await relaunched.add(samples, ingestionTimestamp: ExchangeHarness.start)
        #expect(try relaunched.drainStagedSamples() == beforeCrash)

        try await relaunched.add(samples, ingestionTimestamp: ExchangeHarness.start.addingTimeInterval(60))
        let later = try relaunched.drainStagedSamples()
        for sample in samples {
            let staged = try #require(beforeCrash[sample.uuid])
            let redelivered = try #require(later[sample.uuid])
            #expect(try ExchangeRecord(validating: redelivered).sourceRecord == ExchangeRecord(validating: staged).sourceRecord)
            #expect(try stagedRecordVersion(redelivered) != stagedRecordVersion(staged))
        }
    }

    /// M7, live path: a delivery that spans several sample types stages every sample.
    @Test
    func liveDeliveryStagesEverySampleTypeItSpans() async throws {
        let staging = try await HealthUploadStaging.resolvedForTesting()
        let samples: [HKSample] = [ExchangeHarness.steps(0), ExchangeHarness.steps(1), heartRateSample(2)]
        try await MyHeartCountsStandard.uploadHealthObservations(
            samples,
            accountDataGeneration: LocalPreferencesStore.standard[.accountDataGeneration],
            uploadStrategy: nil,
            through: .testing(staging: staging)
        )
        #expect(Set(try staging.drainStagedSamples().keys) == Set(samples.map(\.uuid)))
    }

    /// M7, live path: a delivery uploaded as one file, as HealthKit types MHC does not model are, is one Bundle of its
    /// records, in sample order, stages no row, and is named by the records' Provenances, never by a sample's HealthKit UUID.
    @Test
    func liveUploadFileIsOneBundleOfTheDeliverysRecords() async throws {
        let staging = try await HealthUploadStaging.resolvedForTesting()
        let files = StagedUploadFiles()
        let accountDataGeneration = LocalPreferencesStore.standard[.accountDataGeneration]
        let samples = (0..<3).map(ExchangeHarness.steps)
        try await MyHeartCountsStandard.uploadHealthObservations(
            samples,
            accountDataGeneration: accountDataGeneration,
            uploadStrategy: .firebaseStorage,
            through: .testing(staging: staging, files: files)
        )
        #expect(try staging.drainStagedSamples().isEmpty)

        #expect(files.all.count == 1)
        let bundle = try ExchangeGraph(validating: try #require(files.all.first), kind: .active)
        #expect(bundle.bundle.id == nil)
        #expect(bundle.transportIdentifier == nil)
        let records = try bundle.records()

        // The upload converts at an instant of its own, so the same exporter repeats its source records, not its versions.
        let delivery = try await staging.healthKitExporter(accountDataGeneration: accountDataGeneration).deliver(samples)
        #expect(records.map(\.sourceRecord) == samples.compactMap { delivery.records[$0.uuid]?.sourceRecord })

        let name = try #require(files.names.first)
        #expect(name == HealthUploadBatch.filename(
            typePrefix: SampleType.stepCount.id,
            provenanceFullURLs: records.map(\.version.fullURL),
            fileExtension: "json.zstd"
        ))
        for sample in samples {
            #expect(!name.localizedCaseInsensitiveContains(sample.uuid.uuidString))
        }
    }
}


// MARK: Live Delivery

extension HealthKitBatchExportTests {
    private struct StageFailure: Error {}

    private struct DeliveryUnavailable: Error {}

    /// M7, live path: `handleNewSamples` stages a delivery the account accepts.
    @Test
    func acceptedDeliveryIsStaged() async throws {
        let staging = try await HealthUploadStaging.resolvedForTesting()
        let samples: [HKSample] = [ExchangeHarness.steps(0), heartRateSample(1)]

        try await MyHeartCountsStandard.handleNewSamples(samples, through: .testing(staging: staging))
        #expect(Set(try staging.drainStagedSamples().keys) == Set(samples.map(\.uuid)))
    }

    /// A delivery the account consumes without staging (signed in, not enrolled) stages nothing, and one it cannot take yet
    /// throws, so Grove keeps the anchor.
    @Test
    func deliveryTheAccountDoesNotAcceptStagesNothing() async throws {
        let staging = try await HealthUploadStaging.resolvedForTesting()
        let samples: [HKSample] = [ExchangeHarness.steps(0), heartRateSample(1)]

        try await MyHeartCountsStandard.handleNewSamples(
            samples,
            through: .testing(staging: staging) { false }
        )
        await #expect(throws: DeliveryUnavailable.self) {
            try await MyHeartCountsStandard.handleNewSamples(
                samples,
                through: .testing(staging: staging) { throw DeliveryUnavailable() }
            )
        }
        #expect(try staging.drainStagedSamples().isEmpty)
    }

    /// A live upload file that fails to stage fails the delivery, so Grove keeps its anchor, and the redelivery states the
    /// same source records.
    @Test
    func liveUploadFileThatFailsToStageIsRedeliveredAsTheSameSourceRecords() async throws {
        let staging = try await HealthUploadStaging.resolvedForTesting()
        let accountDataGeneration = LocalPreferencesStore.standard[.accountDataGeneration]
        let samples = (0..<3).map(ExchangeHarness.steps)
        let attempted = StagedUploadFiles()

        await #expect(throws: StageFailure.self) {
            try await MyHeartCountsStandard.uploadHealthObservations(
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

        let files = StagedUploadFiles()
        try await MyHeartCountsStandard.uploadHealthObservations(
            samples,
            accountDataGeneration: accountDataGeneration,
            uploadStrategy: .firebaseStorage,
            through: .testing(staging: staging, files: files)
        )
        #expect(files.all.count == 1)
        #expect(try files.records.count == samples.count)
        #expect(try files.records.map(\.sourceRecord) == attempted.records.map(\.sourceRecord))
    }
}


extension HealthKitBatchExportTests {
    /// M10: staging holds exchange records only, so an observation the app models itself is refused rather than staged.
    @Test
    func stagingRefusesASelfModelledObservation() async throws {
        let staging = try await HealthUploadStaging.resolvedForTesting()
        let lipids = QuantitySample(
            id: UUID(),
            sampleType: .custom(.bloodLipids),
            unit: QuantitySample.SampleType.custom(.bloodLipids).displayUnit,
            value: 50,
            startDate: ExchangeHarness.start,
            endDate: ExchangeHarness.start
        )

        await #expect(throws: MyHeartCountsStandard.HealthObservationUploadError.unsupportedStrategy) {
            try await staging.add([lipids])
        }
        #expect(try staging.isEmpty)
        #expect(try !staging.stateStore.holdsIdentitySecret, "Refused before the exporter is built, which reads the secret")
    }

    /// M10: the conversion every upload strategy shares builds no exporter for self-modelled observations.
    @Test
    func batchOfSelfModelledObservationsBuildsNoExporter() async throws {
        let lipids = QuantitySample(
            id: UUID(),
            sampleType: .custom(.bloodLipids),
            unit: QuantitySample.SampleType.custom(.bloodLipids).displayUnit,
            value: 50,
            startDate: ExchangeHarness.start,
            endDate: ExchangeHarness.start
        )
        var entries: [PreparedHealthObservationFHIRPayload.Entry] = []
        var exporterBuilds = 0
        let export = try await QuantitySample.export(
            [lipids],
            at: ExchangeHarness.start,
            recordProvider: .healthKit(Self.healthKit),
            exporter: { () throws -> HealthKitFHIRExporter in
                exporterBuilds += 1
                return try ExchangeHarness().exporter()
            }()
        ) { entry in
            entries.append(entry)
        }

        #expect(exporterBuilds == 0)
        #expect(export.refusals.isEmpty)
        #expect(export.warnings.isEmpty)
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

    /// Counts a batch's exporter calls from the outside: a call fetches all its records before it delivers any, so a fetch
    /// after a delivery starts the next call.
    private struct ExporterCallCounter {
        private(set) var calls = 0
        private var isBetweenCalls = true

        mutating func didFetch() {
            if isBetweenCalls {
                calls += 1
                isBetweenCalls = false
            }
        }

        mutating func didDeliver() {
            isBetweenCalls = true
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

    /// Each HealthKit entry carries its record, as the exporter produced it.
    @Test
    func healthKitEntriesCarryTheirRecords() async throws {
        let exporter = try ExchangeHarness().exporter()
        let samples: [HKSample] = [ExchangeHarness.steps(0), heartRateSample(1), Self.symptom]
        var entries: [PreparedHealthObservationFHIRPayload.Entry] = []
        _ = try await exporter.exportBatch(samples, at: ExchangeHarness.start, recordProvider: .healthKit(Self.healthKit)) { entry in
            entries.append(entry)
        }

        let delivery = try await exporter.deliver(samples)
        #expect(entries.map(\.sourceID) == samples.map(\.uuid))
        for entry in entries {
            guard case .record(let record) = entry.content else {
                Issue.record("A HealthKit sample is uploaded as its record")
                continue
            }
            #expect(record.json == delivery.graphs[entry.sourceID])
        }
    }

    /// A batch counts its records' warnings by kind across every exporter call, each sample once, so it logs them once.
    @Test
    func batchReportsItsWarningsOncePerSampleAcrossCalls() async throws {
        let exporter = try ExchangeHarness().exporter()
        // Five calls of eight; no step count names a time zone, so each states both ends of its Period in UTC.
        let export = try await exporter.exportBatch(
            (0..<40).map(ExchangeHarness.steps),
            at: ExchangeHarness.start,
            recordProvider: Self.ecgStandInsRecordProvider(),
            receive: { _ in }
        )
        let kinds = export.warnings.kinds
        #expect(kinds.map(\.code) == [ExchangeGraphRule.mobileOmissionSourceOffset.rawValue])
        #expect(kinds.first?.sampleCountByType == [HKQuantityTypeIdentifier.stepCount.rawValue: 40])
        #expect(kinds.first?.locations == ["Observation.effectivePeriod.start", "Observation.effectivePeriod.end"])

        let zoned = HKQuantitySample(
            type: HKQuantityType(.stepCount),
            quantity: HKQuantity(unit: .count(), doubleValue: 12),
            start: ExchangeHarness.start,
            end: ExchangeHarness.start.addingTimeInterval(30),
            metadata: [HKMetadataKeyTimeZone: "Europe/Berlin"]
        )
        let clean = try await exporter.exportBatch([zoned], at: ExchangeHarness.start, recordProvider: .healthKit(Self.healthKit)) { _ in }
        #expect(clean.warnings.isEmpty)
    }

    /// M16: a batch of 40 ECGs is exported in calls of at most ``HealthKitFHIRExporter/voltageBudget`` voltage
    /// measurements and never keeps more fetched records alive than that; a batch without ECGs is one call.
    @Test
    func ecgBatchNeverHoldsMoreThanTheVoltageBudget() async throws {
        let exporter = try ExchangeHarness().exporter()
        // Each fetch returns a fresh record, as an ECG's fetched voltages are, so only the export keeps it alive.
        var fetched: [FetchedRecord] = []
        var mostHeld = 0
        var counter = ExporterCallCounter()
        let recordProvider: HealthKitFHIRExporter.RecordProvider = ._custom(
            getNumVoltages: { _ in Self.measurementsPerECG },
            getRecord: { sample in
                counter.didFetch()
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
        _ = try await exporter.exportBatch(
            (0..<40).map(ExchangeHarness.steps),
            at: ExchangeHarness.start,
            recordProvider: recordProvider
        ) { _ in
            counter.didDeliver()
            delivered += 1
        }

        #expect(delivered == 40)
        #expect(mostHeld == HealthKitFHIRExporter.voltageBudget)
        #expect(counter.calls == 40 * Self.measurementsPerECG / HealthKitFHIRExporter.voltageBudget)

        var counterWithoutECGs = ExporterCallCounter()
        _ = try await exporter.exportBatch(
            (40..<140).map(ExchangeHarness.steps),
            at: ExchangeHarness.start,
            recordProvider: ._custom(
                getNumVoltages: { _ in 0 },
                getRecord: { sample in
                    counterWithoutECGs.didFetch()
                    return .sample(sample)
                }
            )
        ) { _ in
            counterWithoutECGs.didDeliver()
        }
        #expect(counterWithoutECGs.calls == 1)
    }

    /// A batch that fails after some of its calls completed leaves nothing behind: its redelivery at the same instant
    /// produces the same bytes for those samples, and converts the rest.
    @Test
    func batchFailingAfterEarlierCallsIsRedeliveredExactly() async throws {
        let exporter = try ExchangeHarness().exporter()
        let samples = (0..<40).map(ExchangeHarness.steps)

        var firstAttempt: [UUID: Data] = [:]
        do {
            _ = try await exporter.exportBatch(
                samples,
                at: ExchangeHarness.start,
                recordProvider: Self.ecgStandInsRecordProvider(failingAt: samples[30].uuid)
            ) { entry in
                firstAttempt[entry.sourceID] = try entry.exchangeRecord().json
            }
            Issue.record("A failing fetch ends the batch")
        } catch is FetchFailure {}
        // Three calls of eight completed before the fourth call's records were fetched.
        #expect(Set(firstAttempt.keys) == Set(samples.prefix(24).map(\.uuid)))

        var redelivery: [UUID: Data] = [:]
        _ = try await exporter.exportBatch(
            samples,
            at: ExchangeHarness.start,
            recordProvider: Self.ecgStandInsRecordProvider()
        ) { entry in
            redelivery[entry.sourceID] = try entry.exchangeRecord().json
        }
        #expect(redelivery.count == 40)
        for (sample, json) in firstAttempt {
            #expect(redelivery[sample] == json)
        }
    }
}
