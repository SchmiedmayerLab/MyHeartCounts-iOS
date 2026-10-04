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
    static let empty = Self(refusals: [], receipt: HealthKitFHIRReservationReceipt())

    /// The samples Grove refused; each costs only itself.
    let refusals: [PreparedHealthObservationFHIRPayload.Refusal]
    /// The batch's reservations, one Grove receipt per exporter call. Complete it once the batch's entries are
    /// durably stored and its source cursor is committed.
    let receipt: HealthKitFHIRReservationReceipt
}


/// Where a batch export gets each sample's record from: HealthKit keeps an ECG's voltages and symptoms outside it.
struct HealthObservationRecords {
    /// How many ECG voltage measurements a sample's record holds, known before the record is fetched.
    let voltageMeasurements: (HKSample) -> Int
    /// Fetches a sample's record.
    let record: (HKSample) async throws -> HealthKitFHIRExporter.Record

    /// The records as HealthKit holds them.
    ///
    /// Grove never queries HealthKit, so an ECG's waveform and correlated symptoms are fetched here; each
    /// symptom becomes an event of its own. Every other sample is its own record.
    static func healthKit(_ healthKit: HealthKit) -> Self {
        Self { sample in
            (sample as? HKElectrocardiogram)?.numberOfVoltageMeasurements ?? 0
        } record: { sample in
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
        }
    }
}


/// One batch of health observations, split by how each is converted.
struct HealthObservationBatch: Sendable {
    /// The HealthKit samples, converted by the Grove HealthKit exporter.
    let samples: [HKSample]
    /// The observations the app models itself.
    let selfModelled: [any SelfModelledHealthObservation]

    /// Splits `observations`; an observation of neither kind has no FHIR representation and fails the batch.
    init(_ observations: some Collection<some HealthObservation>) throws {
        var samples: [HKSample] = []
        var selfModelled: [any SelfModelledHealthObservation] = []
        for observation in observations {
            switch observation {
            case let sample as HKSample:
                samples.append(sample)
            case let observation as any SelfModelledHealthObservation:
                selfModelled.append(observation)
            default:
                throw NSError(
                    mhcErrorCode: .unspecified,
                    localizedDescription: "No FHIR representation for '\(observation.sampleTypeIdentifier)'"
                )
            }
        }
        self.samples = samples
        self.selfModelled = selfModelled
    }

    /// Converts the batch, calling `receive` with each entry as soon as it is produced.
    ///
    /// Each self-modelled observation becomes the resource it models. The HealthKit samples go through
    /// ``HealthKitFHIRExporter/exportBatch(_:at:using:receive:)``, under the exporter `exporter` builds. It is
    /// built only when the batch has HealthKit samples, so a batch of self-modelled observations never reads
    /// the identity secret or the app facts, and never touches the ledger.
    func export(
        at instant: Date,
        using healthKit: HealthKit,
        exporter: () async throws -> HealthKitFHIRExporter,
        receive: (PreparedHealthObservationFHIRPayload.Entry) throws -> Void
    ) async throws -> HealthKitBatchExport {
        for observation in selfModelled {
            try Swift::Task.checkCancellation()
            try receive(try observation.fhirEntry(issuedAt: instant))
        }
        guard !samples.isEmpty else {
            return .empty
        }
        return try await exporter().exportBatch(samples, at: instant, using: healthKit, receive: receive)
    }
}


extension HKSample: HealthObservation {
    var id: UUID {
        uuid
    }

    var sampleTypeIdentifier: String {
        sampleType.identifier
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
    /// The resource this observation models, issued at `instant` and carrying MHC's default extensions.
    func fhirResource(issuedAt instant: Date) throws -> AnyEncodable {
        let resourceProxy = try resource(
            issuedDate: FHIRPrimitive<ModelsR4.Instant>(try .init(date: instant)),
            extensions: MyHeartCountsStandard.defaultHealthObservationFHIRExtensions
        )
        return AnyEncodable(FHIRResource(resourceProxy.get()).encodableUnderlyingResource)
    }

    /// ``fhirResource(issuedAt:)`` as an upload entry.
    func fhirEntry(issuedAt instant: Date) throws -> PreparedHealthObservationFHIRPayload.Entry {
        PreparedHealthObservationFHIRPayload.Entry(
            content: .resource(try fhirResource(issuedAt: instant)),
            sourceID: id,
            sourceTypeIdentifier: sampleTypeIdentifier
        )
    }
}


extension HealthKitFHIRExporter {
    /// The most ECG voltage measurements one batch export holds at once: 8 ECGs of 30 s at 512 Hz.
    ///
    /// A batch is split into exporter calls only at this bound, so a batch without ECGs is always one call.
    /// The on-device memory check confirms the value.
    static let voltageBudget = 8 * 15_360

    /// Hands a graph's entry to `receive`, or returns the refusal; neither is logged with the sample's HealthKit
    /// UUID, which must not propagate into logs.
    private static func deliver(
        _ export: Export,
        to receive: (PreparedHealthObservationFHIRPayload.Entry) throws -> Void
    ) throws -> PreparedHealthObservationFHIRPayload.Refusal? {
        switch export.outcome {
        case .graph(let graph):
            for diagnostic in export.warnings {
                logger.notice("Grove converted a \(export.source.typeIdentifier) sample with \(diagnostic.code) at \(diagnostic.location)")
            }
            try receive(PreparedHealthObservationFHIRPayload.Entry(
                content: .graph(graph.json),
                sourceID: export.source.uuid,
                sourceTypeIdentifier: export.source.typeIdentifier
            ))
            return nil
        case .refused(let reason):
            let diagnostic = reason.diagnostic
            logger.warning("Grove refused a \(export.source.typeIdentifier) sample: \(diagnostic.code) at \(diagnostic.location)")
            return PreparedHealthObservationFHIRPayload.Refusal(sourceID: export.source.uuid, reason: reason)
        case .nothingToRetract:
            return nil
        }
    }

    /// Exports one batch of HealthKit samples in as few exporter calls as ``voltageBudget`` allows, calling
    /// `receive` with each graph's entry as soon as it is produced.
    ///
    /// Each call makes one ledger transaction for its reservations and adds one Grove receipt to the
    /// returned receipt. A sample Grove refuses costs only itself: it is logged and reported in
    /// ``HealthKitBatchExport/refusals``, and its reservation is held with the others. When any call or
    /// `receive` throws, the receipts of the earlier calls are dropped with the batch, so their holds lapse
    /// and the redelivery after the retained cursor is an exact retry.
    func exportBatch(
        _ samples: some Collection<some HKSample>,
        at instant: Date,
        using healthKit: HealthKit,
        receive: (PreparedHealthObservationFHIRPayload.Entry) throws -> Void
    ) async throws -> HealthKitBatchExport {
        try await exportBatch(samples, at: instant, records: .healthKit(healthKit), receive: receive)
    }

    /// ``exportBatch(_:at:using:receive:)`` with each sample's record from `records`; tests count what a batch
    /// holds through it.
    func exportBatch(
        _ samples: some Collection<some HKSample>,
        at instant: Date,
        records: HealthObservationRecords,
        receive: (PreparedHealthObservationFHIRPayload.Entry) throws -> Void
    ) async throws -> HealthKitBatchExport {
        var refusals: [PreparedHealthObservationFHIRPayload.Refusal] = []
        var receipts: [ExchangeProducer.Receipt] = []
        var pending: [Record] = []
        var pendingVoltageMeasurements = 0
        func flush() throws {
            guard !pending.isEmpty else {
                return
            }
            receipts.append(try export(records: pending, at: instant) { export in
                // A throw drops this call's receipt, so its holds lapse.
                try Swift::Task.checkCancellation()
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
            let voltageMeasurements = records.voltageMeasurements(sample)
            if voltageMeasurements > 0, pendingVoltageMeasurements + voltageMeasurements > Self.voltageBudget {
                try flush()
            }
            pending.append(try await records.record(sample))
            pendingVoltageMeasurements += voltageMeasurements
        }
        try flush()
        return HealthKitBatchExport(refusals: refusals, receipt: HealthKitFHIRReservationReceipt(receipts))
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
