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

    let entries: [Entry]
}


/// Retry-only event reservations released only after Grove commits the corresponding source cursor.
struct HealthKitFHIRReservationReceipt: Sendable {
    let eventKeys: Set<String>
    private let stateStore: FHIRExchangeStateStore?

    var anchorCommitAction: HealthKitAnchorCommitAction? {
        guard let stateStore, !eventKeys.isEmpty else {
            return nil
        }
        let eventKeys = eventKeys
        return HealthKitAnchorCommitAction {
            try? stateStore.completeHealthKitEvents(eventKeys)
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
        try? stateStore?.completeHealthKitEvents(eventKeys)
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
    private static func preparedEntry(
        bundle: ModelsR4.Bundle,
        sourceID: UUID,
        sourceTypeIdentifier: String,
        eventKey: String,
        postprocess: (inout FHIRResource) throws -> Void
    ) throws -> PreparedHealthObservationFHIRPayload.Entry {
        var resource = FHIRResource(bundle)
        try postprocess(&resource)
        return PreparedHealthObservationFHIRPayload.Entry(
            resource: AnyEncodable(resource.encodableUnderlyingResource),
            sourceID: sourceID,
            sourceTypeIdentifier: sourceTypeIdentifier,
            eventKey: eventKey
        )
    }

    private static func preparedEntries( // swiftlint:disable:this function_parameter_count
        for sample: HKSample,
        conversionInstant: Date,
        subject: FHIRExchangeSubject,
        stateStore: FHIRExchangeStateStore,
        healthKit: HealthKit,
        postprocess: @Sendable (inout FHIRResource) throws -> Void
    ) async throws -> [PreparedHealthObservationFHIRPayload.Entry] {
        let conversions = try await HealthKitConverter().convert(
            sample,
            using: healthKit
        ) { sourceSample in
            try stateStore.healthKitConversion(
                for: sourceSample,
                subject: subject,
                conversionInstant: conversionInstant
            ).context
        }
        return try conversions.all.map { conversion in
            try Self.preparedEntry(
                bundle: conversion.bundle,
                sourceID: conversion.localSourceUUID,
                sourceTypeIdentifier: conversion.localSourceTypeIdentifier,
                eventKey: stateStore.healthKitEventKey(
                    subject: subject,
                    sourceType: conversion.localSourceTypeIdentifier,
                    nativeRecordID: conversion.localSourceUUID
                ),
                postprocess: postprocess
            )
        }
    }

    private static func preparedEntry(
        for observation: any SelfModelledHealthObservation,
        conversionInstant: Date,
        postprocess: (inout FHIRResource) throws -> Void
    ) throws -> PreparedHealthObservationFHIRPayload.Entry {
        let resourceProxy = try observation.resource(
            issuedDate: FHIRPrimitive<ModelsR4.Instant>(try .init(date: conversionInstant)),
            extensions: MyHeartCountsStandard.defaultHealthObservationFHIRExtensions
        )
        var resource = FHIRResource(resourceProxy.get())
        try postprocess(&resource)
        return PreparedHealthObservationFHIRPayload.Entry(
            resource: AnyEncodable(resource.encodableUnderlyingResource),
            sourceID: observation.id,
            sourceTypeIdentifier: observation.sampleTypeIdentifier,
            eventKey: nil
        )
    }

    /// Produces the FHIR payload persisted for this observation.
    ///
    /// A HealthKit sample converts through the Grove HealthKit adapter, which yields an exchange
    /// Bundle holding the Observation, the recording and converting Devices, and the conversion
    /// Provenance. Provider-issued clinical FHIR remains byte-preserved inside an R4 recording-
    /// document graph. Everything without a Grove adapter is modelled by the app itself.
    func prepareFHIRPayload( // swiftlint:disable:this function_body_length
        conversionInstant: Date,
        subject: FHIRExchangeSubject,
        stateStore: FHIRExchangeStateStore,
        using healthKit: HealthKit,
        postprocess: @Sendable (inout FHIRResource) throws -> Void = { _ in }
    ) async throws -> PreparedHealthObservationFHIRPayload {
        var entries: [PreparedHealthObservationFHIRPayload.Entry]
        switch self {
        case let record as HKClinicalRecord:
            let reservation = try stateStore.healthKitConversion(
                for: record,
                subject: subject,
                conversionInstant: conversionInstant
            )
            let conversion = try HealthKitConverter().convert(record, context: reservation.context)
            entries = [
                try Self.preparedEntry(
                    bundle: conversion.bundle,
                    sourceID: record.uuid,
                    sourceTypeIdentifier: record.sampleType.identifier,
                    eventKey: reservation.eventKey,
                    postprocess: postprocess
                )
            ]
        case let document as HKCDADocumentSample:
            let reservation = try stateStore.healthKitConversion(
                for: document,
                subject: subject,
                conversionInstant: conversionInstant
            )
            let conversion = try HealthKitConverter().convert(document, context: reservation.context)
            entries = [
                try Self.preparedEntry(
                    bundle: conversion.bundle,
                    sourceID: document.uuid,
                    sourceTypeIdentifier: document.sampleType.identifier,
                    eventKey: reservation.eventKey,
                    postprocess: postprocess
                )
            ]
        case let sample as HKSample:
            entries = try await Self.preparedEntries(
                for: sample,
                conversionInstant: conversionInstant,
                subject: subject,
                stateStore: stateStore,
                healthKit: healthKit,
                postprocess: postprocess
            )
        case let observation as any SelfModelledHealthObservation:
            entries = [
                try Self.preparedEntry(
                    for: observation,
                    conversionInstant: conversionInstant,
                    postprocess: postprocess
                )
            ]
        default:
            throw NSError(
                mhcErrorCode: .unspecified,
                localizedDescription: "No FHIR representation for '\(sampleTypeIdentifier)'"
            )
        }
        return PreparedHealthObservationFHIRPayload(entries: entries)
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
