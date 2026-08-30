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
        let application = HealthKitApplication.main
        let host = FHIRExchangeRuntimeFacts.host
        let event = try event(
            key: eventKey,
            recordedAt: conversionInstant,
            facts: FHIRExchangeEventFacts(
                applicationToken: application.bundleIdentifier,
                applicationName: application.name,
                applicationVersion: application.version,
                applicationBuild: application.build,
                hostToken: host.sourceDeviceToken,
                hostOperatingSystemVersion: host.operatingSystemVersion,
                hostName: host.name,
                hostManufacturer: host.manufacturer,
                hostModelNumber: host.modelNumber,
                researchStudyIDs: FHIRExchangeIdentifiers.currentResearchStudyIDs()
            )
        )
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
                repositoryScope: repositoryScope(.healthKit),
                sourceActor: .application,
                converterWasGateway: true,
                conversionInstant: event.recordedAt,
                recordingDeviceStableUnitToken: sample.device?.localIdentifier,
                udiDisclosurePolicy: .omit,
                nativeIdentifierDisclosurePolicy: .authorized(
                    system: FHIRExchangeIdentifiers.healthKitNativeRecord
                ),
                routeDisclosurePolicy: .omit,
                protocolCanonical: nil,
                researchStudies: FHIRExchangeIdentifiers.researchStudyReferences(for: event.researchStudyIDs)
            )
        )
    }
}
