//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

// swiftlint:disable all

import struct ModelsR4.Questionnaire
import struct ModelsR4.QuestionnaireResponse
import MyHeartCountsShared
import SpeziFoundation
import SpeziQuestionnaire
import SpeziQuestionnaireFHIR
import SpeziQuestionnaireLegacy
import SwiftUI


//struct MHCQuestionnaireSheet: View {
//    @AccountFeatureFlagQuery(.useNewQuestionnaireUI)
//    private var useNewUI
//    
//    @Environment(MyHeartCountsStandard.self)
//    private var standard
//    
//    private let r4Questionnaire: Result<ModelsR4.Questionnaire, any Error>
//    private let speziQuestionnaire: Result<SpeziQuestionnaire.Questionnaire, any Error>
//    private let completionHandler: (_ success: Bool) async -> Void
//    
//    var body: some View {
//        if useNewUI {
//            switch speziQuestionnaire {
//            case .success(let questionnaire):
//                QuestionnaireSheet(questionnaire, completionStepConfig: .disable) { result in
//                    switch result {
//                    case .cancelled:
//                        await completionHandler(false)
//                    case .completed(let responses):
//                        do {
//                            let fhirResponse = try ModelsR4.QuestionnaireResponse(responses)
//                            await standard.add(responses, for: r4Questionnaire.value)
//                            await completionHandler(true)
//                        } catch {
//                            await completionHandler(false)
//                        }
//                    }
//                }
//            case .failure(let error):
//                ContentUnavailableView(
//                    "Unable to load questionnaire" as String,
//                    systemSymbol: .xmarkOctagon,
//                    description: Text(String(describing: error))
//                )
//            }
//        } else {
//            switch r4Questionnaire {
//            case .success(let questionnaire):
//                QuestionnaireView(questionnaire: questionnaire, cancelBehavior: .shouldConfirmCancel) { result in
//                    switch result {
//                    case .cancelled:
//                        await completionHandler(false)
//                        break
//                    case .completed(let response):
//                        await standard.add(response, for: questionnaire)
//                    case .failed:
//                        await completionHandler(false)
//                    }
//                }
//            case .failure(let error):
//                ContentUnavailableView(
//                    "Unable to load questionnaire" as String,
//                    systemSymbol: .xmarkOctagon,
//                    description: Text(String(describing: error))
//                )
//            }
//        }
//    }
//    
//    init(_ questionnaire: ModelsR4.Questionnaire, completionHandler: (_ success: Bool) async -> Void = { _ in }) {
//        self.r4Questionnaire = .success(questionnaire)
//        self.speziQuestionnaire = Result {
//            try SpeziQuestionnaire.Questionnaire(questionnaire)
//        }
//        self.completionHandler = completionHandler
//    }
//    
//    init(_ questionnaire: SpeziQuestionnaire.Questionnaire, completionHandler: (_ success: Bool) async -> Void = { _ in }) {
//        self.speziQuestionnaire = questionnaire
//        self.r4Questionnaire = .failure(NSError(localizedDescription: "Can't convert a Spezi Questionnaire to FHIR one"))
//        self.completionHandler = completionHandler
//    }
//}


extension AccountFeatureFlags.FeatureFlagDefinition {
    static let useNewQuestionnaireUI = Self(sources: [
        .launchOption(.useNewQuestionnaireUI),
        .localPreference(.useNewQuestionnaireUI)
    ])
}


extension LocalPreferenceKeys {
    /// Opt-in to use the new questionnaire UI from SpeziQuestionnaire, instead of using the legacy ResearchKit-based UI.
    static let useNewQuestionnaireUI = LocalPreferenceKey<Bool>("useNewQuestionnaireUI", default: false)
}
