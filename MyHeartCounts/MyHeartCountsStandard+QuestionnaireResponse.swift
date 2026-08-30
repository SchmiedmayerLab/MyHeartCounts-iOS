//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

@preconcurrency import FirebaseFirestore
import Grove
import GroveFHIRContract
import GroveFoundation
import GroveHealthKit
import GroveQuestionnaire
import GroveQuestionnaireFHIR
import ModelsR4
import MyHeartCountsShared
import OSLog


/// Converts the main-actor questionnaire state before crossing into the app's Standard actor.
@MainActor
func submitQuestionnaire(
    _ responses: GroveQuestionnaire.QuestionnaireResponses,
    to standard: MyHeartCountsStandard,
    authored: Date = .now,
    authoredTimeZone: TimeZone = .current
) async throws {
    let submission = try await standard.questionnaireSubmissionContext()
    let writerContext = try QuestionnaireWriterContext.current(
        applicationIdentifierSystem: FHIRExchangeIdentifiers.application
    )
    let pair = try ResourceBuilder().pair(
        from: responses,
        subject: submission.subject.reference,
        author: submission.subject.reference,
        responseSource: submission.subject.reference,
        writerContext: writerContext,
        authored: authored,
        authoredTimeZone: authoredTimeZone
    )
    try await standard.add(pair.response, destination: submission.destination)
}


struct QuestionnaireSubmissionContext: Sendable {
    let subject: FHIRExchangeSubject
    let destination: FHIRExchangeDestination
}


extension MyHeartCountsStandard {
    func questionnaireSubmissionContext() async throws -> QuestionnaireSubmissionContext {
        let preferences = LocalPreferencesStore.standard
        let generation = preferences[.accountDataGeneration]
        guard !preferences[.pendingAccountDataCleanupRequired] else {
            throw FHIRExchangeDestinationError.accountChanged
        }
        let subject = try await firebaseConfiguration.fhirExchangeSubject
        let destination = FHIRExchangeDestination(
            accountDataGeneration: generation,
            accountID: subject.identity.value
        )
        try destination.validateCurrentAccount()
        return QuestionnaireSubmissionContext(subject: subject, destination: destination)
    }

    func add(
        _ response: ModelsR4.QuestionnaireResponse,
        destination: FHIRExchangeDestination
    ) async throws {
        guard let id = response.identifier?.value?.value?.string else {
            throw ContractError.incompleteResponseIdentifier
        }
        try destination.validateCurrentAccount()
        let document = FirebaseConfiguration.usersCollection
            .document(destination.accountID)
            .collection("questionnaireResponses")
            .document(id)
        let data = try Firestore.Encoder().encode(response)
        try await document.setData(data)
        await parseIfApplicable(response)
        if let timestamp = try? response.authored?.value?.asNSDate() {
            await achievementsManager?.record(.completeQuestionnaire, timestamp: timestamp)
        }
    }
    
    
    // periphery:ignore:parameters isolation
    private func parseIfApplicable(
        isolation: isolated (any Actor)? = #isolation,
        _ response: ModelsR4.QuestionnaireResponse
    ) async {
        typealias Rule = QuestionnaireDataExtractor.Rule
        switch response.questionnaireCanonicalIdentity?.url.absoluteString {
        case "https://myheartcounts.stanford.edu/fhir/survey/heartRisk":
            await processSurvey(response: response, rules: [
                Rule.bloodPressure(
                    systolicLinkId: "7cec349c-495c-4ef6-834e-cc9708625736",
                    diastolicLinkId: "b25ac0aa-4528-47dc-951f-97f411ec5cc2"
                ),
                Rule.quantitySample(.bloodPressureSystolic, linkId: "78edc19f-e409-49f0-8e42-a0adf5e777b0"),
                Rule.quantitySample(.bloodGlucose, linkId: "7309938e-ea24-4e31-8427-82f3a1a44f83")
            ])
        default:
            break
        }
    }
    
    
    private func processSurvey(
        isolation: isolated (any Actor)? = #isolation,
        response: QuestionnaireResponse,
        rules: [any QuestionnaireDataExtractor.AnyRule<HealthKit>]
    ) async {
        let extractor = QuestionnaireDataExtractor(response: response)
        for rule in rules {
            do {
                _ = try await rule(isolation: isolation, extractor: extractor, context: healthKit)
            } catch {
                await logger.error("Error parsing & processing questionnaire response: \(error)")
            }
        }
    }
}
