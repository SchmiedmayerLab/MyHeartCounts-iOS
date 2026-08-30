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
import GroveHealthKitFHIR
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
        // The instrument's own SDC markings drive extraction: the response is projected into
        // the full Grove exchange bundle -- identities, devices, provenance -- and each of the
        // bundle's Observations lands as the HealthKit sample it describes, synced under its
        // minted source-output identity. The bundle itself is discarded for now; the server
        // will own the exchange-side extraction.
        guard let canonical = response.questionnaireCanonicalIdentity,
              let responseID = response.identifier?.value?.value?.string,
              let studyManager,
              let questionnaire = await Self.enrolledQuestionnaire(for: canonical, in: studyManager) else {
            return
        }
        do {
            let reservation = try fhirExchangeStateStore(
                accountDataGeneration: LocalPreferencesStore.standard[.accountDataGeneration]
            ).questionnaireConversion(
                responseID: responseID,
                subject: try await firebaseConfiguration.fhirExchangeSubject,
                conversionInstant: .now
            )
            let graph = try QuestionnaireExchangeProjection.exchangeGraph(
                questionnaire: questionnaire,
                response: response,
                context: reservation.context
            )
            for entry in graph.bundle.entry ?? [] {
                guard case .observation(let observation) = entry.resource else {
                    continue
                }
                do {
                    let sample = try HealthKitSampleProjection.sample(for: observation)
                    try await healthKit.save(sample)
                } catch {
                    // One refusal (an unmapped measurement, an undetermined authorization)
                    // loses that reading, never the whole response's extraction.
                    await logger.error("Unable to project extracted observation into HealthKit: \(error)")
                }
            }
        } catch ObservationExtractionError.noExtractableMeasurements {
            // A survey that measures nothing is the common case, not an error.
        } catch {
            await logger.error("Error parsing & processing questionnaire response: \(error)")
        }
    }
}
