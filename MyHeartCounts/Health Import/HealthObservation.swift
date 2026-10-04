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


struct PreparedHealthObservationFHIRPayload {
    struct Entry {
        let resource: AnyEncodable
        let sourceID: UUID
        let sourceTypeIdentifier: String
    }

    /// One record the adapter permanently refuses, kept so a batch never drops it silently.
    struct Refusal: Sendable {
        let sourceID: UUID
        let reason: HealthKitConversionError
    }

    let entries: [Entry]
    let refusals: [Refusal]
    /// The exchange-event reservations behind `entries`; `nil` for a payload the app modelled itself.
    let receipt: HealthKitFHIRExporter.Receipt?

    init(entries: [Entry], refusals: [Refusal] = [], receipt: HealthKitFHIRExporter.Receipt? = nil) {
        self.entries = entries
        self.refusals = refusals
        self.receipt = receipt
    }
}


/// Retry-only event reservations released only after Grove commits the corresponding source cursor.
struct HealthKitFHIRReservationReceipt: Sendable {
    private let receipts: [HealthKitFHIRExporter.Receipt]

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

    init(_ receipts: some Sequence<HealthKitFHIRExporter.Receipt>) {
        self.receipts = Array(receipts)
    }

    init(payloads: some Sequence<PreparedHealthObservationFHIRPayload>) {
        self.init(payloads.compactMap(\.receipt))
    }

    init(merging receipts: some Sequence<HealthKitFHIRReservationReceipt>) {
        self.init(receipts.flatMap(\.receipts))
    }

    /// Cleanup is best-effort and idempotent: the source cursor is already durable at this point.
    func completeAfterSourceAcknowledgement() {
        for receipt in receipts {
            receipt.release()
        }
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


// MARK: Utils

extension HealthObservation {
    private static func entry(
        graph: ExchangeGraph,
        source: HealthKitFHIRExporter.Export.Source
    ) -> PreparedHealthObservationFHIRPayload.Entry {
        PreparedHealthObservationFHIRPayload.Entry(
            resource: AnyEncodable(FHIRResource(graph.bundle).encodableUnderlyingResource),
            sourceID: source.uuid,
            sourceTypeIdentifier: source.typeIdentifier
        )
    }

    /// Grove never queries HealthKit, so an ECG's waveform and correlated symptoms are fetched here;
    /// each symptom becomes an event of its own.
    private static func record(
        for sample: HKSample,
        using healthKit: HealthKit
    ) async throws -> HealthKitFHIRExporter.Record {
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

    /// Converts one sample under the batch's exporter.
    ///
    /// A record the adapter permanently refuses is recorded as a refusal and its reservation is
    /// released: the adapter's refusals are deterministic, so an exact redelivery refuses
    /// identically, and failing the batch instead would retain the source anchor and block every
    /// newer sample of the type.
    private static func samplePayload(
        for sample: HKSample,
        exporter: HealthKitFHIRExporter,
        at conversionInstant: Date,
        healthKit: HealthKit
    ) async throws -> PreparedHealthObservationFHIRPayload {
        let record = try await Self.record(for: sample, using: healthKit)
        var entries: [PreparedHealthObservationFHIRPayload.Entry] = []
        var refusals: [PreparedHealthObservationFHIRPayload.Refusal] = []
        let receipt = try exporter.export(records: CollectionOfOne(record), at: conversionInstant) { export in
            switch export.outcome {
            case .graph(let graph):
                for diagnostic in export.warnings {
                    logger.notice(
                        "Grove converted \(export.source.typeIdentifier) \(export.source.uuid) with \(diagnostic.code) at \(diagnostic.location)"
                    )
                }
                entries.append(Self.entry(graph: graph, source: export.source))
            case .refused(let reason):
                let diagnostic = reason.diagnostic
                logger.warning(
                    "Grove refused \(export.source.typeIdentifier) \(export.source.uuid): \(diagnostic.code) at \(diagnostic.location) (\(String(describing: reason)))"
                )
                refusals.append(PreparedHealthObservationFHIRPayload.Refusal(sourceID: export.source.uuid, reason: reason))
            case .nothingToRetract:
                break
            }
        }
        return PreparedHealthObservationFHIRPayload(entries: entries, refusals: refusals, receipt: receipt)
    }

    private static func selfModelledPayload(
        for observation: any SelfModelledHealthObservation,
        conversionInstant: Date
    ) throws -> PreparedHealthObservationFHIRPayload {
        let resourceProxy = try observation.resource(
            issuedDate: FHIRPrimitive<ModelsR4.Instant>(try .init(date: conversionInstant)),
            extensions: MyHeartCountsStandard.defaultHealthObservationFHIRExtensions
        )
        return PreparedHealthObservationFHIRPayload(entries: [
            PreparedHealthObservationFHIRPayload.Entry(
                resource: AnyEncodable(FHIRResource(resourceProxy.get()).encodableUnderlyingResource),
                sourceID: observation.id,
                sourceTypeIdentifier: observation.sampleTypeIdentifier
            )
        ])
    }

    /// Produces the FHIR payload persisted for this observation.
    ///
    /// A HealthKit sample converts through the Grove HealthKit exporter, which yields an exchange
    /// Bundle holding the Observation, the recording and converting Devices, and the conversion
    /// Provenance. Provider-issued clinical FHIR remains byte-preserved inside an R4 recording-
    /// document graph. Everything without a Grove adapter is modelled by the app itself.
    ///
    /// A record the adapter permanently refuses is reported as a refusal rather than thrown, so one
    /// unconvertible sample never costs its batch or its sample type's ingestion.
    ///
    /// Callers converting many observations share one exporter built by
    /// `FHIRExchangeStateStore.healthKitExporter(subject:ledger:)`.
    func prepareFHIRPayload(
        with exporter: HealthKitFHIRExporter,
        at conversionInstant: Date,
        using healthKit: HealthKit
    ) async throws -> PreparedHealthObservationFHIRPayload {
        switch self {
        case let sample as HKSample:
            return try await Self.samplePayload(
                for: sample,
                exporter: exporter,
                at: conversionInstant,
                healthKit: healthKit
            )
        case let observation as any SelfModelledHealthObservation:
            return try Self.selfModelledPayload(
                for: observation,
                conversionInstant: conversionInstant
            )
        default:
            throw NSError(
                mhcErrorCode: .unspecified,
                localizedDescription: "No FHIR representation for '\(sampleTypeIdentifier)'"
            )
        }
    }

    /// Produces the FHIR payload of this observation alone, with an exporter of its own.
    func prepareFHIRPayload(
        conversionInstant: Date,
        subject: FHIRExchangeSubject,
        stateStore: FHIRExchangeStateStore,
        ledger: FHIRExchangeLedger,
        using healthKit: HealthKit
    ) async throws -> PreparedHealthObservationFHIRPayload {
        try await prepareFHIRPayload(
            with: try stateStore.healthKitExporter(subject: subject, ledger: ledger),
            at: conversionInstant,
            using: healthKit
        )
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
