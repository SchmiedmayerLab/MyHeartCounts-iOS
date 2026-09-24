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
        let eventKey = healthKitEventKey(
            subject: subject,
            sourceType: sample.sampleType.identifier,
            nativeRecordID: sample.uuid
        )
        let event = try event(key: eventKey, recordedAt: conversionInstant, facts: .current())
        // Converting a stored record does not make MHC a gateway; it mediated only the samples it wrote.
        let mediated = sample.sourceRevision.source.bundleIdentifier == event.facts.applicationBundleIdentifier
        return HealthKitConversionReservation(
            eventKey: eventKey,
            context: HealthKitConversionContext(
                event: try eventContext(
                    for: event,
                    subject: subject,
                    repository: .healthKit,
                    converterRole: mediated ? .gateway : .assembler,
                    repositoryIDs: [.bundle: RepositoryID(healthKitRecord: sample.uuid)]
                ),
                options: .myHeartCounts
            )
        )
    }
}
