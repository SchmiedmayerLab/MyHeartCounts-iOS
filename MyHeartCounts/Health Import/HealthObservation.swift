//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import FHIRModelsExtensions
import Foundation
import GroveHealthKit
import GroveHealthKitFHIR
import HealthKit
import ModelsR4
import MyHeartCountsShared
import Synchronization


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
        let eventKey: String?
    }

    /// One record the adapter permanently refuses, kept so a batch never drops it silently.
    struct Refusal: Sendable {
        let sourceID: UUID
        let sourceTypeIdentifier: String
        let reason: HealthKitConversionError
    }

    let entries: [Entry]
    let refusals: [Refusal]

    init(entries: [Entry], refusals: [Refusal] = []) {
        self.entries = entries
        self.refusals = refusals
    }
}


/// Retry-only event reservations released only after Grove commits the corresponding source cursor.
struct HealthKitFHIRReservationReceipt: Sendable {
    let eventKeys: Set<String>
    private let stateStore: FHIRExchangeStateStore?

    var anchorCommitAction: HealthKitAnchorCommitAction? {
        guard stateStore != nil, !eventKeys.isEmpty else {
            return nil
        }
        return HealthKitAnchorCommitAction {
            self.completeAfterSourceAcknowledgement()
        }
    }

    init() {
        self.stateStore = nil
        self.eventKeys = []
    }

    init(
        stateStore: FHIRExchangeStateStore,
        eventKeys: some Sequence<String>
    ) {
        self.stateStore = stateStore
        self.eventKeys = Set(eventKeys)
    }

    init(
        stateStore: FHIRExchangeStateStore,
        entries: some Sequence<PreparedHealthObservationFHIRPayload.Entry>
    ) {
        self.init(stateStore: stateStore, eventKeys: entries.compactMap(\.eventKey))
    }

    /// Cleanup is best-effort and idempotent: the source cursor is already durable at this point.
    func completeAfterSourceAcknowledgement() {
        try? stateStore?.completeExchangeEvents(eventKeys)
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
        bundle: ModelsR4.Bundle,
        sourceID: UUID,
        sourceTypeIdentifier: String,
        eventKey: String
    ) -> PreparedHealthObservationFHIRPayload.Entry {
        PreparedHealthObservationFHIRPayload.Entry(
            resource: AnyEncodable(FHIRResource(bundle).encodableUnderlyingResource),
            sourceID: sourceID,
            sourceTypeIdentifier: sourceTypeIdentifier,
            eventKey: eventKey
        )
    }

    /// Records a permanently refused record and releases the reservations it will never use.
    ///
    /// The adapter's refusals are deterministic, so an exact redelivery refuses identically. Failing
    /// the batch instead would retain the source anchor and block every newer sample of the type.
    private static func refusal(
        of sample: HKSample,
        reason: HealthKitConversionError,
        reservedEventKeys: some Sequence<String>,
        stateStore: FHIRExchangeStateStore
    ) -> PreparedHealthObservationFHIRPayload {
        try? stateStore.completeExchangeEvents(reservedEventKeys)
        logger.warning(
            "Grove refused \(sample.sampleType.identifier) \(sample.uuid): \(String(describing: reason))"
        )
        let refusal = PreparedHealthObservationFHIRPayload.Refusal(
            sourceID: sample.uuid,
            sourceTypeIdentifier: sample.sampleType.identifier,
            reason: reason
        )
        return PreparedHealthObservationFHIRPayload(entries: [], refusals: [refusal])
    }

    /// Converts one document-shaped sample, whose graph the caller's closure assembles.
    ///
    /// The document conversion type is named rather than inferred: a clinical record is also an
    /// `HKSample`, so a closure returning ``HealthKitConversion`` would resolve to the Observation
    /// overload and refuse every provider-issued document as platform-exclusive.
    private static func documentPayload(
        for sample: HKSample,
        conversionInstant: Date,
        subject: FHIRExchangeSubject,
        stateStore: FHIRExchangeStateStore,
        convert: (HealthKitConversionContext) throws -> HealthKitDocumentConversion
    ) throws -> PreparedHealthObservationFHIRPayload {
        let reservation = try stateStore.healthKitConversion(
            for: sample,
            subject: subject,
            conversionInstant: conversionInstant
        )
        do {
            let conversion = try convert(reservation.context)
            return PreparedHealthObservationFHIRPayload(entries: [
                Self.entry(
                    bundle: conversion.bundle,
                    sourceID: sample.uuid,
                    sourceTypeIdentifier: sample.sampleType.identifier,
                    eventKey: reservation.eventKey
                )
            ])
        } catch let error as HealthKitConversionError {
            return Self.refusal(
                of: sample,
                reason: error,
                reservedEventKeys: CollectionOfOne(reservation.eventKey),
                stateStore: stateStore
            )
        }
    }

    /// Grove never queries HealthKit, so an ECG's waveform and correlated symptoms are fetched here
    /// and handed to the converter as evidence.
    private static func conversions(
        of sample: HKSample,
        using healthKit: HealthKit,
        contextForSample: (HKSample) throws -> HealthKitConversionContext
    ) async throws -> HealthKitConversionSet {
        guard let electrocardiogram = sample as? HKElectrocardiogram else {
            return HealthKitConversionSet(
                primary: try HealthKitConverter().convert(
                    sample,
                    context: try contextForSample(sample)
                )
            )
        }
        async let voltageMeasurements = electrocardiogram.rawVoltageMeasurements(
            from: healthKit.healthStore
        )
        async let correlatedSymptoms = electrocardiogram.correlatedSymptomSamples(from: healthKit)
        return try HealthKitConverter().convert(
            electrocardiogram,
            voltageMeasurements: try await voltageMeasurements,
            correlatedSymptoms: try await correlatedSymptoms,
            contextForSample: contextForSample
        )
    }

    private static func samplePayload(
        for sample: HKSample,
        conversionInstant: Date,
        subject: FHIRExchangeSubject,
        stateStore: FHIRExchangeStateStore,
        healthKit: HealthKit
    ) async throws -> PreparedHealthObservationFHIRPayload {
        let reservedEventKeys = Mutex<Set<String>>([])
        let reservationFailure = Mutex<(any Error)?>(nil)
        do {
            let conversions = try await Self.conversions(
                of: sample,
                using: healthKit
            ) { sourceSample in
                do {
                    let reservation = try stateStore.healthKitConversion(
                        for: sourceSample,
                        subject: subject,
                        conversionInstant: conversionInstant
                    )
                    reservedEventKeys.withLock { $0.insert(reservation.eventKey) }
                    return reservation.context
                } catch {
                    reservationFailure.withLock { $0 = $0 ?? error }
                    throw error
                }
            }
            return PreparedHealthObservationFHIRPayload(entries: conversions.all.map { conversion in
                Self.entry(
                    bundle: conversion.bundle,
                    sourceID: conversion.localSourceUUID,
                    sourceTypeIdentifier: conversion.localSourceTypeIdentifier,
                    eventKey: stateStore.healthKitEventKey(
                        subject: subject,
                        sourceType: conversion.localSourceTypeIdentifier,
                        nativeRecordID: conversion.localSourceUUID
                    )
                )
            })
        } catch let error as HealthKitConversionError {
            // Grove narrows anything the context provider throws into an opaque conversion failure,
            // and a locked keychain during background delivery is transient rather than a refusal.
            // The batch fails on the original error so the anchor redelivers the record, and the
            // reservations already made stay so the retry mints the same event identities.
            if let reservationFailure = reservationFailure.withLock({ $0 }) {
                throw reservationFailure
            }
            return Self.refusal(
                of: sample,
                reason: error,
                reservedEventKeys: reservedEventKeys.withLock { $0 },
                stateStore: stateStore
            )
        }
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
                sourceTypeIdentifier: observation.sampleTypeIdentifier,
                eventKey: nil
            )
        ])
    }

    /// Produces the FHIR payload persisted for this observation.
    ///
    /// A HealthKit sample converts through the Grove HealthKit adapter, which yields an exchange
    /// Bundle holding the Observation, the recording and converting Devices, and the conversion
    /// Provenance. Provider-issued clinical FHIR remains byte-preserved inside an R4 recording-
    /// document graph. Everything without a Grove adapter is modelled by the app itself.
    ///
    /// A record the adapter permanently refuses is reported as a refusal rather than thrown, so one
    /// unconvertible sample never costs its batch or its sample type's ingestion.
    func prepareFHIRPayload(
        conversionInstant: Date,
        subject: FHIRExchangeSubject,
        stateStore: FHIRExchangeStateStore,
        using healthKit: HealthKit
    ) async throws -> PreparedHealthObservationFHIRPayload {
        switch self {
        case let record as HKClinicalRecord:
            return try Self.documentPayload(
                for: record,
                conversionInstant: conversionInstant,
                subject: subject,
                stateStore: stateStore
            ) { context in
                try HealthKitConverter().convert(record, context: context)
            }
        case let document as HKCDADocumentSample:
            return try Self.documentPayload(
                for: document,
                conversionInstant: conversionInstant,
                subject: subject,
                stateStore: stateStore
            ) { context in
                try HealthKitConverter().convert(document, context: context)
            }
        case let sample as HKSample:
            return try await Self.samplePayload(
                for: sample,
                conversionInstant: conversionInstant,
                subject: subject,
                stateStore: stateStore,
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
