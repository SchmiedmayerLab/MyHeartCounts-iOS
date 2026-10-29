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


extension MyHeartCountsStandard {
    struct QuestionnaireAuthorDate: Sendable {
        static var now: Self {
            Self(date: .now, timeZone: .current)
        }
        
        let date: Date
        let timeZone: TimeZone
    }
    
    
    struct QuestionnaireSubmissionContext: Sendable {
        let subject: FHIRExchangeSubject
        let destination: FHIRExchangeDestination
    }
    
    
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
                      let questionnaire = bundle.questionnaire(for: questionnaireComponent.fileRef),
                      questionnaire.canonicalIdentity == canonical else {
                    continue
                }
                return questionnaire
            }
        }
        return nil
    }
    
    private func questionnaireSubmissionContext() async throws -> QuestionnaireSubmissionContext {
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
    
    /// - parameter locale: is the one the questionnaire was rendered in; its language becomes `QuestionnaireResponse.language`.
    nonisolated func add(
        _ responses: GroveQuestionnaire.QuestionnaireResponses,
        renderedIn locale: Locale,
        authoredDate: QuestionnaireAuthorDate = .now
    ) async throws {
        let submission = try await self.questionnaireSubmissionContext()
        let writerContext = try QuestionnaireWriterContext.current(
            applicationIdentifierSystem: FHIRExchangeIdentifiers.application
        )
        let pair = try ResourceBuilder().pair(
            from: responses,
            subject: submission.subject.reference,
            author: submission.subject.reference,
            responseSource: submission.subject.reference,
            writerContext: writerContext,
            renderedIn: locale,
            authored: authoredDate.date,
            authoredTimeZone: authoredDate.timeZone
        )
        let response = pair.response
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
        if let timestamp = try? response.authored?.value?.asNSDate() {
            await achievementsManager?.record(.completeQuestionnaire, timestamp: timestamp)
        }
    }
}


extension MyHeartCountsStandard {
    /// The HealthKit samples the measurements `response` extracts land as, through `exporter`.
    ///
    /// Extraction has no retry to protect: the response is already durable and its exchange graph is discarded, so the
    /// response's event is released at once, however extraction concludes.
    ///
    /// - returns: `nil` when the response measures nothing.
    /// - throws: The `ObservationExtractionError` Grove refused the response with, or what the ledger threw.
    static func healthKitSamples( // private but testable
        extractedFrom response: ModelsR4.QuestionnaireResponse,
        answering questionnaire: ModelsR4.Questionnaire,
        through exporter: QuestionnaireFHIRExporter,
        at instant: Date = .now
    ) async throws -> ConversionBatch<HKSample, HealthKitSampleProjectionFailure>? {
        var outcomes: [QuestionnaireFHIRExporter.Export.Outcome] = []
        let receipt = try await exporter.export(CollectionOfOne(.init(questionnaire: questionnaire, response: response)), at: instant) { export in
            outcomes.append(export.outcome)
        }
        receipt.release()
        switch outcomes.first {
        case .graph(let graph):
            return graph.healthKitSamples()
        case .refused(.noExtractableMeasurements), nil:
            return nil
        case .refused(let refusal):
            throw refusal
        }
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
              let studyManager,
              let questionnaire = await Self.enrolledQuestionnaire(for: canonical, in: studyManager) else {
            return
        }
        do {
            // The submission's captured account, never the current one: an account switch between
            // the Firestore write and here must refuse, not re-target this response.
            try submission.destination.validateCurrentAccount()
            let exporter = try fhirExchangeStateStore(
                accountDataGeneration: submission.destination.accountDataGeneration
            ).questionnaireExporter(subject: submission.subject, ledger: fhirExchangeLedger)
            guard let samples = try await Self.healthKitSamples(extractedFrom: response, answering: questionnaire, through: exporter) else {
                // A survey that measures nothing is the common case, not an error.
                return
            }
            // One refusal (an unmapped measurement) loses that reading, never the response.
            for failure in samples.failures {
                let diagnostic = failure.error.diagnostic
                logger.error(
                    "Unable to project extracted observation: \(diagnostic.code) at \(diagnostic.location) (\(String(describing: failure.error)))"
                )
            }
            for sample in samples.conversions {
                do {
                    try await healthKit.save(sample)
                } catch {
                    logger.error("Unable to save extracted sample into HealthKit: \(error)")
                }
            }
        } catch {
            logger.error("Error parsing & processing questionnaire response: \(error)")
        }
    }
}
