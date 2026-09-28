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
        let eventKey: String?
    }

    /// One record the adapter permanently refuses, kept so a batch never drops it silently.
    struct Refusal: Sendable {
        let sourceID: UUID
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
        let diagnostic = reason.diagnostic
        logger.warning(
            "Grove refused \(sample.sampleType.identifier) \(sample.uuid): \(diagnostic.code) at \(diagnostic.location) (\(String(describing: reason)))"
        )
        let refusal = PreparedHealthObservationFHIRPayload.Refusal(
            sourceID: sample.uuid,
            reason: reason
        )
        return PreparedHealthObservationFHIRPayload(entries: [], refusals: [refusal])
    }

    /// Converts one sample under its reserved context; Grove never queries HealthKit, so an ECG's
    /// waveform and correlated symptoms are fetched here and each symptom gets its own event.
    private static func conversions(
        of sample: HKSample,
        context: HealthKitConversionContext,
        using healthKit: HealthKit,
        reserve: (HKSample) throws -> HealthKitConversionReservation
    ) async throws -> HealthKitConversionSet {
        switch sample {
        case let electrocardiogram as HKElectrocardiogram:
            async let voltageMeasurements = electrocardiogram.rawVoltageMeasurements(from: healthKit.healthStore)
            async let correlatedSymptoms = electrocardiogram.correlatedSymptomSamples(from: healthKit)
            let record = HealthKitECGRecord(
                electrocardiogram: electrocardiogram,
                voltageMeasurements: try await voltageMeasurements,
                correlatedSymptoms: try await correlatedSymptoms
            )
            return try HealthKitConverter().convert(
                record,
                context: context,
                symptomContexts: try record.correlatedSymptoms.map { try reserve($0).context }
            )
        case let record as HKClinicalRecord:
            return try HealthKitConverter().convert(record, context: context)
        case let document as HKCDADocumentSample:
            return try HealthKitConverter().convert(document, context: context)
        default:
            return try HealthKitConverter().convert(sample, context: context)
        }
    }

    private static func samplePayload(
        for sample: HKSample,
        conversionInstant: Date,
        subject: FHIRExchangeSubject,
        stateStore: FHIRExchangeStateStore,
        healthKit: HealthKit
    ) async throws -> PreparedHealthObservationFHIRPayload {
        var reservedEventKeys: [String] = []
        func reserve(_ sample: HKSample) throws -> HealthKitConversionReservation {
            let reservation = try stateStore.healthKitConversion(
                for: sample,
                subject: subject,
                conversionInstant: conversionInstant
            )
            reservedEventKeys.append(reservation.eventKey)
            return reservation
        }
        let conversions: HealthKitConversionSet
        do {
            conversions = try await Self.conversions(
                of: sample,
                context: try reserve(sample).context,
                using: healthKit,
                reserve: reserve
            )
        } catch let error as HealthKitConversionError {
            return Self.refusal(
                of: sample,
                reason: error,
                reservedEventKeys: reservedEventKeys,
                stateStore: stateStore
            )
        }
        for conversion in conversions.all {
            for warning in conversion.warnings {
                let diagnostic = warning.diagnostic
                logger.notice(
                    "Grove converted \(conversion.source.type.rawValue) \(conversion.source.uuid) with \(diagnostic.code) at \(diagnostic.location)"
                )
            }
        }
        return PreparedHealthObservationFHIRPayload(entries: conversions.all.map { conversion in
            Self.entry(
                bundle: conversion.bundle,
                sourceID: conversion.source.uuid,
                sourceTypeIdentifier: conversion.source.type.rawValue,
                eventKey: stateStore.healthKitEventKey(
                    subject: subject,
                    sourceType: conversion.source.type.rawValue,
                    nativeRecordID: conversion.source.uuid
                )
            )
        })
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
