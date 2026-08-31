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
import HealthKit
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
    try await standard.add(pair.response, in: submission)
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
        // Read before the await: capturing it afterwards would compare the current generation with
        // itself and let an account rotation that happened during the await through.
        let accountDataGeneration = LocalPreferencesStore.standard[.accountDataGeneration]
        let subject = try await firebaseConfiguration.fhirExchangeSubject
        return QuestionnaireSubmissionContext(
            subject: subject,
            destination: try FHIRExchangeDestination.capture(
                accountID: subject.identity.value,
                accountDataGeneration: accountDataGeneration
            )
        )
    }

    func add(
        _ response: ModelsR4.QuestionnaireResponse,
        in submission: QuestionnaireSubmissionContext
    ) async throws {
        guard let id = response.identifier?.value?.value?.string else {
            throw ContractError.incompleteResponseIdentifier
        }
        try submission.destination.validateCurrentAccount()
        let document = FirebaseConfiguration.usersCollection
            .document(submission.destination.accountID)
            .collection("questionnaireResponses")
            .document(id)
        let data = try Firestore.Encoder().encode(response)
        try await document.setData(data)
        await parseIfApplicable(response, in: submission)
    }


    private func parseIfApplicable(
        _ response: ModelsR4.QuestionnaireResponse,
        in submission: QuestionnaireSubmissionContext
    ) async {
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
            // The submission's captured account, never the current one: an account switch between
            // the Firestore write and here must refuse, not re-target this response.
            try submission.destination.validateCurrentAccount()
            let stateStore = fhirExchangeStateStore(
                accountDataGeneration: submission.destination.accountDataGeneration
            )
            let reservation = try stateStore.questionnaireConversion(
                responseID: responseID,
                subject: submission.subject,
                conversionInstant: .now
            )
            // Extraction has no retry to protect: the response is already durable and the bundle is
            // discarded, so the reservation is released however extraction concludes.
            defer {
                try? stateStore.completeExchangeEvents(CollectionOfOne(reservation.eventKey))
            }
            let graph = try QuestionnaireExchangeProjection.exchangeGraph(
                questionnaire: questionnaire,
                response: response,
                context: reservation.context
            )
            // One refusal (an unmapped measurement) loses that reading, never the response.
            var refusals: [any Error] = []
            let samples = HealthKitSampleProjection.samples(in: graph) { refusals.append($0) }
            for refusal in refusals {
                logger.error("Unable to project extracted observation: \(refusal)")
            }
            for sample in samples {
                do {
                    try await healthKit.save(sample)
                } catch {
                    logger.error("Unable to save extracted sample into HealthKit: \(error)")
                }
            }
        } catch ObservationExtractionError.noExtractableMeasurements {
            // A survey that measures nothing is the common case, not an error.
        } catch {
            await logger.error("Error parsing & processing questionnaire response: \(error)")
        }
    }
}


extension HealthKitSampleProjection {
    /// Every Observation in an exchange graph that projects back into a HealthKit sample.
    ///
    /// One refusal loses that reading and is reported; the remaining measurements still land. Both
    /// production and its tests read the graph through here, so they cannot disagree about it.
    static func samples(
        in graph: ExchangeGraph,
        onRefusal: (any Error) -> Void
    ) -> [HKSample] {
        (graph.bundle.entry ?? []).compactMap { entry -> HKSample? in
            guard case .observation(let observation) = entry.resource else {
                return nil
            }
            do {
                return try Self.sample(for: observation)
            } catch {
                onRefusal(error)
                return nil
            }
        }
    }
}
