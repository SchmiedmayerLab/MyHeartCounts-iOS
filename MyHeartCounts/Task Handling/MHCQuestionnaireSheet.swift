//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import class ModelsR4.Questionnaire
import class ModelsR4.QuestionnaireResponse
import SpeziFoundation
import SpeziQuestionnaire
import SpeziQuestionnaireFHIR
import SwiftUI


struct MHCQuestionnaireSheet: View {
    @Environment(MyHeartCountsStandard.self)
    private var standard
    
    private let completionHandler: @MainActor (_ success: Bool) -> Void
    
    @State private var fhir: ModelsR4.Questionnaire
    @State private var spezi: Result<SpeziQuestionnaire.Questionnaire, any Error>?
    
    @LocalPreference(.useNewQuestionnaireUI)
    private var useNewQuestionnaireUI
    
    var body: some View {
        VStack {
            if useNewQuestionnaireUI {
                switch spezi {
                case nil:
                    EmptyView()
                case .success(let questionnaire):
                    newImpl(questionnaire)
                case .failure:
                    legacyImpl()
                }
            } else {
                legacyImpl()
            }
        }
        .task {
            if useNewQuestionnaireUI {
                spezi = .init { try .init(fhir) }
            }
        }
    }
    
    init(_ questionnaire: ModelsR4.Questionnaire, completionHandler: @escaping @MainActor (_ success: Bool) -> Void) {
        self.fhir = questionnaire
        self.completionHandler = completionHandler
    }
    
    private func legacyImpl() -> some View {
        QuestionnaireView(questionnaire: fhir) { (result: QuestionnaireResult) in
            switch result {
            case .completed(let response):
                await standard.add(response, for: fhir)
                completionHandler(true)
            case .cancelled, .failed:
                completionHandler(false)
            }
        }
    }
    
    private func newImpl(_ questionnaire: SpeziQuestionnaire.Questionnaire) -> some View {
        QuestionnaireSheet(questionnaire, completionStepConfig: .enable) { (result: QuestionnaireSheet.Result) in
            switch result {
            case .completed(let responses):
                await standard.add(responses)
                completionHandler(true)
            case .cancelled:
                completionHandler(false)
            }
        }
    }
}


extension LocalPreferenceKeys {
    static let useNewQuestionnaireUI = LocalPreferenceKey<Bool>("useNewQuestionnaireUI", default: false)
}
