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
import GroveStudy
import GroveStudyDefinition
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
    @MainActor
    private static func enrolledQuestionnaire(
        for canonical: QuestionnaireCanonicalIdentity,
        in studyManager: StudyManager
    ) -> ModelsR4.Questionnaire? {
        for enrollment in studyManager.studyEnrollments {
            guard let bundle = enrollment.studyBundle else {
                continue
            }
            for component in bundle.studyDefinition.components {
                guard case .questionnaire(let questionnaireComponent) = component,
                      let questionnaire = bundle.questionnaire(
                          for: questionnaireComponent.fileRef,
                          in: .current
                      ),
                      questionnaire.canonicalIdentity?.url == canonical.url else {
                    continue
                }
                return questionnaire
            }
        }
        return nil
    }

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
    
    
    private func parseIfApplicable(_ response: ModelsR4.QuestionnaireResponse) async {
        // The instrument's own SDC markings drive extraction: an item marked with
        // `observationExtract` and carrying its measurement code becomes a HealthKit sample,
        // so instruments declare what they measure instead of the app hardcoding linkIds.
        guard let canonical = response.questionnaireCanonicalIdentity,
              let studyManager,
              let questionnaire = await Self.enrolledQuestionnaire(for: canonical, in: studyManager) else {
            return
        }
        do {
            let samples = try QuestionnaireHealthKitSampleProjection.samples(
                questionnaire: questionnaire,
                response: response
            )
            for sample in samples {
                try await healthKit.save(sample)
            }
        } catch {
            await logger.error("Error parsing & processing questionnaire response: \(error)")
        }
    }
}
