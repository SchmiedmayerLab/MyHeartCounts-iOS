//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFHIRContract
import GroveHealthKitFHIR
import HealthKit


struct HealthKitConversionReservation: Sendable {
    let eventKey: String
    let context: HealthKitConversionContext
}


/// The HealthKit conversion reservations of one batch.
///
/// The initializer reserves every given sample's event in a single ledger transaction and reads
/// the identity facts once, so converting the batch costs a constant number of encrypted ledger
/// passes instead of several per sample. A sample not reserved up front, such as an ECG's
/// correlated symptom, is reserved on demand together with the other samples of the same request.
struct HealthKitConversionBatch: Sendable {
    private struct Reserved: Sendable {
        let events: [String: PersistedFHIRExchangeEvent]
        let scope: FHIRExchangeEventScope
    }

    let stateStore: FHIRExchangeStateStore
    let subject: FHIRExchangeSubject
    let conversionInstant: Date
    /// `nil` when the batch holds no HealthKit sample, so it never touches the ledger.
    private let reserved: Reserved?

    init(
        reserving samples: some Sequence<HKSample>,
        subject: FHIRExchangeSubject,
        conversionInstant: Date,
        stateStore: FHIRExchangeStateStore
    ) throws {
        self.stateStore = stateStore
        self.subject = subject
        self.conversionInstant = conversionInstant
        let keys = samples.map { Self.eventKey(for: $0, subject: subject, in: stateStore) }
        guard !keys.isEmpty else {
            self.reserved = nil
            return
        }
        let (events, scope) = try Self.reserve(
            keys,
            subject: subject,
            conversionInstant: conversionInstant,
            in: stateStore
        )
        self.reserved = Reserved(
            events: Dictionary(zip(keys, events)) { first, _ in first },
            scope: scope
        )
    }

    private static func eventKey(
        for sample: HKSample,
        subject: FHIRExchangeSubject,
        in stateStore: FHIRExchangeStateStore
    ) -> String {
        stateStore.healthKitEventKey(
            subject: subject,
            sourceType: sample.sampleType.identifier,
            nativeRecordID: sample.uuid
        )
    }

    private static func reserve(
        _ keys: [String],
        subject: FHIRExchangeSubject,
        conversionInstant: Date,
        in stateStore: FHIRExchangeStateStore
    ) throws -> (events: [PersistedFHIRExchangeEvent], scope: FHIRExchangeEventScope) {
        let reservations = try stateStore.events(
            forKeys: keys,
            recordedAt: conversionInstant,
            facts: .current()
        )
        return (
            reservations.events,
            try stateStore.eventScope(.healthKit, subject: subject, producerInstance: reservations.producerInstance)
        )
    }

    /// The reserved context of one sample.
    func reservation(for sample: HKSample) throws -> HealthKitConversionReservation {
        try reservations(for: [sample])[0]
    }

    /// The reserved contexts of `samples`, in order; reserves them in one transaction unless the
    /// batch already did.
    func reservations(for samples: [HKSample]) throws -> [HealthKitConversionReservation] {
        let keys = samples.map { Self.eventKey(for: $0, subject: subject, in: stateStore) }
        if let reserved {
            let events = keys.compactMap { reserved.events[$0] }
            if events.count == keys.count {
                return try reservations(for: samples, keys: keys, events: events, scope: reserved.scope)
            }
        }
        guard !keys.isEmpty else {
            return []
        }
        let (events, scope) = try Self.reserve(
            keys,
            subject: subject,
            conversionInstant: conversionInstant,
            in: stateStore
        )
        return try reservations(for: samples, keys: keys, events: events, scope: scope)
    }

    private func reservations(
        for samples: [HKSample],
        keys: [String],
        events: [PersistedFHIRExchangeEvent],
        scope: FHIRExchangeEventScope
    ) throws -> [HealthKitConversionReservation] {
        try zip(samples, zip(keys, events)).map { sample, reservation in
            let (eventKey, event) = reservation
            // Converting a stored record does not make MHC a gateway; it mediated only the samples it wrote.
            let mediated = sample.sourceRevision.source.bundleIdentifier == event.facts.applicationBundleIdentifier
            return HealthKitConversionReservation(
                eventKey: eventKey,
                context: HealthKitConversionContext(
                    event: try scope.context(
                        for: event,
                        subject: subject,
                        converterRole: mediated ? .gateway : .assembler,
                        repositoryIDs: [.bundle: RepositoryID(healthKitRecord: sample.uuid)]
                    ),
                    options: .myHeartCounts
                )
            )
        }
    }
}


extension HealthKitConversionOptions {
    /// Discloses the HealthKit UUID under MHC's own system on every output and retraction target.
    static let myHeartCounts = Self(
        nativeIdentifierDisclosure: .authorized(system: FHIRExchangeIdentifiers.healthKitNativeRecord)
    )
}


extension RepositoryID {
    /// The Firestore document id a HealthKit record's graph is stored under.
    init(healthKitRecord uuid: UUID) throws {
        try self.init(uuid.uuidString)
    }
}


extension FHIRExchangeStateStore {
    /// Reserves and reconstructs the complete deterministic context for one HealthKit source version.
    func healthKitConversion(
        for sample: HKSample,
        subject: FHIRExchangeSubject,
        conversionInstant: Date
    ) throws -> HealthKitConversionReservation {
        try HealthKitConversionBatch(
            reserving: CollectionOfOne(sample),
            subject: subject,
            conversionInstant: conversionInstant,
            stateStore: self
        ).reservation(for: sample)
    }
}
