//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFHIRContract
import GroveHealthKitFHIR
import GroveQuestionnaireFHIR
import ModelsR4


struct QuestionnaireConversionReservation: Sendable {
    let eventKey: String
    let context: QuestionnaireExtractionContext
}


extension FHIRExchangeStateStore {
    /// Reserves and reconstructs the complete deterministic context for one questionnaire response.
    func questionnaireConversion(
        responseID: String,
        subject: FHIRExchangeSubject,
        conversionInstant: Date
    ) throws -> QuestionnaireConversionReservation {
        let eventKey = questionnaireEventKey(subject: subject, responseID: responseID)
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
        return try QuestionnaireConversionReservation(
            eventKey: eventKey,
            context: QuestionnaireExtractionContext(
                patient: Patient(identifier: [subject.identity.fhirIdentifier]),
                eventIdentifier: eventIdentifier(for: event),
                identityScope: identityScope(),
                repositoryScope: repositoryScope(.questionnaire, subject: subject),
                entryNodeIdentifierSystem: FHIRExchangeIdentifiers.entryNode,
                conversionInstant: event.recordedAt
            )
        )
    }
}
