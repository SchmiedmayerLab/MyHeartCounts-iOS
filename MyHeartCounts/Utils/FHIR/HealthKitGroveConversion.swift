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
        let event = try event(key: eventKey, recordedAt: conversionInstant, facts: .current)
        return try HealthKitConversionReservation(
            eventKey: eventKey,
            context: HealthKitConversionContext(
                subject: subject.reference,
                subjectIdentity: subject.identity,
                converter: event.healthKitApplication,
                converterHost: event.healthKitHost,
                eventIdentifier: eventIdentifier(for: event),
                entryNodeIdentifierSystem: FHIRExchangeIdentifiers.entryNode,
                identityScope: identityScope(),
                repositoryScope: repositoryScope(.healthKit, subject: subject),
                sourceActor: .application,
                // Converting a stored record does not make the converter a gateway; MHC mediated
                // the recording only for samples it wrote itself.
                converterWasGateway: sample.sourceRevision.source.bundleIdentifier
                    == event.facts.applicationToken,
                conversionInstant: event.recordedAt,
                recordingDeviceStableUnitToken: sample.device?.localIdentifier,
                udiDisclosurePolicy: .omit,
                nativeIdentifierDisclosurePolicy: .authorized(
                    system: FHIRExchangeIdentifiers.healthKitNativeRecord
                ),
                routeDisclosurePolicy: .omit,
                protocolCanonical: nil,
                researchStudies: FHIRExchangeIdentifiers.researchStudyReferences(
                    for: event.facts.researchStudyIDs
                )
            )
        )
    }
}
