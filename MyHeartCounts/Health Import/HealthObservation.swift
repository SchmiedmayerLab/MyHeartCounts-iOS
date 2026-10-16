//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import FHIRModelsExtensions
import Foundation
import GroveFHIRContract
import GroveHealthKit
import GroveHealthKitFHIR
import HealthKit
import ModelsR4
import MyHeartCountsShared


// swiftlint:disable:next file_types_order
protocol HealthObservation: Sendable { // might want to rename this (@lukas); the resulting ResourceProxy is not necessarily an Observation...)
    var id: UUID { get }
    var sampleTypeIdentifier: String { get }

    /// Converts `batch`, calling `receive` with each entry as soon as it is produced.
    ///
    /// HealthKit samples go through ``HealthKitFHIRExporter/exportBatch(_:at:using:receive:)`` under the exporter
    /// `exporter` returns; observations the app models itself become the resources they model and never call
    /// `exporter`, so they upload even while no HealthKit exporter is available.
    static func export(
        _ batch: some Collection<Self>,
        at instant: Date,
        recordProvider: HealthKitFHIRExporter.RecordProvider,
        exporter: @autoclosure () throws -> HealthKitFHIRExporter,
        receive: (PreparedHealthObservationFHIRPayload.Entry) throws -> Void
    ) async throws -> HealthKitBatchExport
}


/// A health observation whose FHIR representation My Heart Counts builds itself.
///
/// Covers only app-produced observations for which no Grove adapter exists, such as active-task
/// results and dashboard measurements. SensorKit exchange uses the Grove SensorKit adapters.
protocol SelfModelledHealthObservation: HealthObservation {
    func resource(
        issuedDate: ModelsR4.FHIRPrimitive<ModelsR4.Instant>?,
        extensions: [any FHIRExtensionBuilderProtocol]
    ) throws -> ModelsR4.ResourceProxy
}


/// What converting health observations produces, one entry at a time.
enum PreparedHealthObservationFHIRPayload {
    /// One converted observation, as it is uploaded.
    struct Entry {
        enum Content {
            /// A Grove exchange graph's validated bytes, `ExchangeGraph.json`, uploaded verbatim.
            case graph(Data)
            /// A resource the app modelled itself, encoded when it is uploaded.
            case resource(AnyEncodable)
        }

        let content: Content
        let sourceID: UUID
        let sourceTypeIdentifier: String

        /// The bytes this entry is uploaded as: a graph's own, or the resource in the upload encoding.
        func json() throws -> Data {
            switch content {
            case .graph(let json):
                json
            case .resource(let resource):
                try HealthUploadBatch.encoder.encode(resource)
            }
        }
    }

    /// One record the adapter permanently refuses, kept so a batch never drops it silently.
    struct Refusal: Sendable {
        let sourceID: UUID
        let reason: HealthKitConversionError
    }
}


/// Retry-only event reservations released only after Grove commits the corresponding source cursor.
struct HealthKitFHIRReservationReceipt: Sendable {
    private let receipts: [ExchangeProducer.Receipt]

    var isEmpty: Bool {
        receipts.isEmpty
    }

    var anchorCommitAction: HealthKitAnchorCommitAction? {
        guard !receipts.isEmpty else {
            return nil
        }
        return HealthKitAnchorCommitAction {
            self.completeAfterSourceAcknowledgement()
        }
    }

    init() {
        self.receipts = []
    }

    init(_ receipts: some Sequence<ExchangeProducer.Receipt>) {
        self.receipts = Array(receipts)
    }

    init(merging receipts: some Sequence<HealthKitFHIRReservationReceipt>) {
        self.init(receipts.flatMap(\.receipts))
    }

    /// Cleanup is best-effort and idempotent: the source cursor is already durable at this point.
    ///
    /// Each Grove receipt releases at most once, also when copies of this value complete it again.
    func completeAfterSourceAcknowledgement() {
        for receipt in receipts {
            receipt.release()
        }
    }
}


/// What one batch's HealthKit export left behind besides its entries.
struct HealthKitBatchExport: Sendable {
    /// Nothing exported, nothing reserved.
    static let empty = Self(refusals: [], warnings: HealthKitFHIRExporter.WarningReport(), receipt: HealthKitFHIRReservationReceipt())

    /// The samples Grove refused; each costs only itself.
    let refusals: [PreparedHealthObservationFHIRPayload.Refusal]
    /// The kinds of warning the batch's graphs raised, logged once for the batch rather than once per sample.
    let warnings: HealthKitFHIRExporter.WarningReport
    /// The batch's reservations, one Grove receipt per exporter call. Complete it once the batch's entries are
    /// durably stored and its source cursor is committed.
    let receipt: HealthKitFHIRReservationReceipt
}


extension HKSample: HealthObservation {
    var id: UUID {
        uuid
    }

    var sampleTypeIdentifier: String {
        sampleType.identifier
    }
    
    static func export(
        _ batch: some Collection<some HKSample>,
        at instant: Date,
        recordProvider: HealthKitFHIRExporter.RecordProvider,
        exporter: @autoclosure () throws -> HealthKitFHIRExporter,
        receive: (PreparedHealthObservationFHIRPayload.Entry) throws -> Void
    ) async throws -> HealthKitBatchExport {
        guard !batch.isEmpty else {
            return .empty
        }
        let exporter = try exporter()
        return try await HealthKitExportLog.record(.live, samples: HealthKitExportLog.counts(batch), exporter: exporter) {
            try await exporter.exportBatch(batch, at: instant, recordProvider: recordProvider, receive: receive)
        }
    }
}


extension TimedWalkingTestResult: SelfModelledHealthObservation {
    static let sampleTypeIdentifier = "MHCHealthObservationTimedWalkingTestResultIdentifier"

    var sampleTypeIdentifier: String {
        Self.sampleTypeIdentifier
    }
}


// MARK: Conversion

extension SelfModelledHealthObservation {
    static func export(
        _ batch: some Collection<Self>,
        at instant: Date,
        recordProvider _: HealthKitFHIRExporter.RecordProvider,
        exporter _: @autoclosure () throws -> HealthKitFHIRExporter,
        receive: (PreparedHealthObservationFHIRPayload.Entry) throws -> Void
    ) async throws -> HealthKitBatchExport {
        guard !batch.isEmpty else {
            return .empty
        }
        // Once per batch, not per observation: creating FHIR date/time primitives from a `Date` was measured to be expensive.
        let issuedAt = try FHIRPrimitive<ModelsR4.Instant>(.init(date: instant, timeZone: .current))
        for observation in batch {
            try Swift::Task.checkCancellation()
            try receive(try observation.fhirEntry(issuedAt: issuedAt))
        }
        return .empty
    }

    /// The resource this observation models, issued at `instant` and carrying MHC's default extensions.
    private func fhirResource(issuedAt: FHIRPrimitive<ModelsR4.Instant>) throws -> AnyEncodable {
        let resourceProxy = try resource(
            issuedDate: issuedAt,
            extensions: MyHeartCountsStandard.defaultHealthObservationFHIRExtensions
        )
        return AnyEncodable(FHIRResource(resourceProxy.get()).encodableUnderlyingResource)
    }

    /// ``fhirResource(issuedAt:)`` as an upload entry.
    private func fhirEntry(issuedAt: FHIRPrimitive<ModelsR4.Instant>) throws -> PreparedHealthObservationFHIRPayload.Entry {
        PreparedHealthObservationFHIRPayload.Entry(
            content: .resource(try fhirResource(issuedAt: issuedAt)),
            sourceID: id,
            sourceTypeIdentifier: sampleTypeIdentifier
        )
    }
}


extension HealthKitFHIRExporter {
    /// Used to obtain a `HKSample`'s `HealthKitFHIRExporter.Record`
    enum RecordProvider {
        /// Fetches the sample's record from HealthKit.
        /// The records as HealthKit holds them.
        ///
        /// Grove never queries HealthKit, so an ECG's waveform and correlated symptoms are fetched here; each
        /// symptom becomes an event of its own. Every other sample is its own record.
        case healthKit(HealthKit)
        /// Exists solely for testing purposes.
        case _custom( // swiftlint:disable:this identifier_name
            getNumVoltages: (HKSample) -> Int,
            getRecord: (HKSample) async throws -> HealthKitFHIRExporter.Record
        )
        
        func voltageMeasurements(for sample: HKSample) -> Int {
            switch self {
            case .healthKit:
                (sample as? HKElectrocardiogram)?.numberOfVoltageMeasurements ?? 0
            case ._custom(let getNumVoltages, getRecord: _):
                getNumVoltages(sample)
            }
        }
        
        func record(for sample: HKSample) async throws -> Record {
            switch self {
            case .healthKit(let healthKit):
                guard let electrocardiogram = sample as? HKElectrocardiogram else {
                    return .sample(sample)
                }
                async let voltageMeasurements = electrocardiogram.rawVoltageMeasurements(from: healthKit.healthStore)
                async let correlatedSymptoms = electrocardiogram.correlatedSymptomSamples(from: healthKit)
                return .electrocardiogram(
                    electrocardiogram,
                    voltages: try await voltageMeasurements,
                    symptoms: try await correlatedSymptoms
                )
            case ._custom(getNumVoltages: _, let getRecord):
                return try await getRecord(sample)
            }
        }
    }
    
    /// The most ECG voltage measurements one batch export holds at once: 8 ECGs of 30 s at 512 Hz.
    ///
    /// A batch is split into exporter calls only at this bound, so a batch without ECGs is always one call.
    /// The on-device memory check confirms the value.
    static let voltageBudget = 8 * 15_360

    /// Hands a graph's entry to `receive`, or returns the refusal; a refusal is logged without the sample's HealthKit
    /// UUID, which must not propagate into logs.
    private static func deliver(
        _ export: Export,
        to receive: (PreparedHealthObservationFHIRPayload.Entry) throws -> Void
    ) throws -> PreparedHealthObservationFHIRPayload.Refusal? {
        switch export.outcome {
        case .graph(let graph):
            try receive(PreparedHealthObservationFHIRPayload.Entry(
                content: .graph(graph.json),
                sourceID: export.source.uuid,
                sourceTypeIdentifier: export.source.typeIdentifier
            ))
            return nil
        case .refused(let reason):
            let diagnostic = reason.diagnostic
            logger.error("Grove refused a \(export.source.typeIdentifier) sample: \(diagnostic.code) at \(diagnostic.location)")
            return PreparedHealthObservationFHIRPayload.Refusal(sourceID: export.source.uuid, reason: reason)
        }
    }

    /// Exports one batch of HealthKit samples in as few exporter calls as ``voltageBudget`` allows, calling
    /// `receive` with each graph's entry as soon as it is produced.
    ///
    /// Each call makes one ledger transaction for its reservations and adds one Grove receipt to the
    /// returned receipt. A sample Grove refuses costs only itself: it is logged and reported in
    /// ``HealthKitBatchExport/refusals``, and its reservation is held with the others. The graphs' warnings
    /// are counted by kind across every call into ``HealthKitBatchExport/warnings`` and logged once, when the
    /// batch has exported: a historical export raises the same few for almost every sample. When any call or
    /// `receive` throws, the receipts of the earlier calls are dropped with the batch, so their holds lapse
    /// and the redelivery after the retained cursor is an exact retry; its warnings are logged then.
    func exportBatch(
        _ samples: some Collection<some HKSample>,
        at instant: Date,
        recordProvider: RecordProvider,
        receive: (PreparedHealthObservationFHIRPayload.Entry) throws -> Void
    ) async throws -> HealthKitBatchExport {
        var refusals: [PreparedHealthObservationFHIRPayload.Refusal] = []
        var warnings = WarningReport()
        var receipts: [ExchangeProducer.Receipt] = []
        var pending: [Record] = []
        var pendingVoltageMeasurements = 0
        func flush() async throws {
            guard !pending.isEmpty else {
                return
            }
            receipts.append(try await export(records: pending, at: instant) { export in
                // A throw drops this call's receipt, so its holds lapse.
                try Swift::Task.checkCancellation()
                warnings.add(export)
                if let refusal = try Self.deliver(export, to: receive) {
                    refusals.append(refusal)
                }
            })
            pending.removeAll(keepingCapacity: true)
            pendingVoltageMeasurements = 0
        }
        for sample in samples {
            try Swift::Task.checkCancellation()
            // Exported before the fetch, so the voltages held never exceed the budget but for one ECG larger than it.
            let voltageMeasurements = recordProvider.voltageMeasurements(for: sample)
            if voltageMeasurements > 0, pendingVoltageMeasurements + voltageMeasurements > Self.voltageBudget {
                try await flush()
            }
            pending.append(try await recordProvider.record(for: sample))
            pendingVoltageMeasurements += voltageMeasurements
        }
        try await flush()
        if !warnings.isEmpty {
            logger.info("Grove exported \(samples.count) HealthKit samples with warnings:\n\(warnings.description)")
        }
        if let throughput {
            // Cumulative for this exporter, which live ingestion and the historical upload share.
            logger.info("\(throughput.description)")
        }
        return HealthKitBatchExport(refusals: refusals, warnings: warnings, receipt: HealthKitFHIRReservationReceipt(receipts))
    }
}


extension FHIRResource {
    var encodableUnderlyingResource: any Encodable {
        switch self {
        case .r4(let resource):
            resource
        case .dstu2(let resource):
            resource
        }
    }
}
