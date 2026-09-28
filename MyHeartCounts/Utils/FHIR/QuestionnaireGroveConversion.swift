//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFHIRContract
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
        let event = try event(key: eventKey, recordedAt: conversionInstant, facts: .current())
        let scope = try identityScope()
        return QuestionnaireConversionReservation(
            eventKey: eventKey,
            context: QuestionnaireExtractionContext(
                patient: Patient(identifier: [subject.identity.fhirIdentifier]),
                eventIdentifier: try eventIdentifier(for: event, in: scope),
                identityScope: scope,
                repositoryScope: try repositoryScope(.questionnaire, subject: subject),
                conversionInstant: event.recordedAt
            )
        )
    }
}
