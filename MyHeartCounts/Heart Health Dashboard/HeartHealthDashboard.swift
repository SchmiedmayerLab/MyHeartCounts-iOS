//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

// swiftlint:disable file_types_order all

import Foundation
import MHCStudyDefinition
import struct ModelsR4.Questionnaire
import struct ModelsR4.QuestionnaireResponse
import MyHeartCountsShared
import SFSafeSymbols
import SpeziFoundation
import SpeziHealthKit
import SpeziHealthKitUI
import SpeziQuestionnaire
import SpeziQuestionnaireFHIR
import SpeziQuestionnaireLegacy
import SpeziStudy
import SpeziViews
import SwiftUI


struct HeartHealthDashboard: View {
    private struct MetricDescriptor: Identifiable {
        let keyPath: KeyPath<CVHScore, ScoreResult>
        var id: ObjectIdentifier { .init(keyPath) }
    }
    
    @Environment(StudyManager.self)
    private var studyManager
    
    @CVHScore private var cvhScore
    
    @State private var scoreResultToExplain: MetricDescriptor?
    @State private var isPresentingPastTimedWalkTestResults = false
    
    var body: some View {
        Form {
            healthDashboard
        }
        .sheet(item: $scoreResultToExplain) { descriptor in
            NavigationStack {
                DetailedHealthStatsView(descriptor.keyPath)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            DismissButton()
                        }
                    }
            }
        }
        .adaptiveSheet(isPresented: $isPresentingPastTimedWalkTestResults) {
            NavigationStack {
                PastTimedWalkTestResults()
                    .taskPerformingAnchor()
            }
        }
    }
    
    @ViewBuilder private var healthDashboard: some View {
        Group {
            HealthDashboardSection {
                topSection
            }
            HealthDashboardGridSection(
                "Score Components",
                footer: "HHD_APPLE_WATCH_REQUIRED_FOOTER"
            ) {
                switch $cvhScore.preferredExerciseMetric {
                case .exerciseMinutes:
                    makeGridTile(for: \.physicalExerciseScore)
                case .stepCount:
                    makeGridTile(for: \.stepCountScore)
                }
                makeGridTile(for: \.sleepHealthScore)
                makeGridTile(for: \.dietScore)
                makeGridTile(for: \.mentalHealthScore)
                makeGridTile(for: \.bloodPressureScore)
                makeGridTile(for: \.bloodLipidsScore)
                makeGridTile(for: \.bloodGlucoseScore)
                makeGridTile(for: \.bodyMassIndexScore)
                makeGridTile(for: \.nicotineExposureScore)
            }
        }
        .makeBackgroundMatchFormBackground()
        learnMoreSection
        pastDataSection
    }
    
    
    @ViewBuilder private var topSection: some View {
        let valueAvailabe = !(cvhScore?.isNaN ?? true)
        VStack { // swiftlint:disable:this closure_body_length
            HStack {
                Spacer()
                Gauge(
                    lineWidth: .relative(2),
                    gradient: valueAvailabe ? .redToGreen : Gradient(colors: [.gray]),
                    progress: cvhScore
                ) {
                    if let cvhScore, !cvhScore.isNaN {
                        if #available(iOS 26.0, *) {
                            Text(Int(cvhScore * 100), format: .number)
                                .font(.largeTitle.scaled(by: 1.2).bold())
                        } else {
                            Text(Int(cvhScore * 100), format: .number)
                                .font(.largeTitle.bold())
                        }
                    } else {
                        Text("—")
                            .font(.largeTitle.bold())
                            .foregroundStyle(.secondary)
                    }
                } minimumValueText: {
                    Text("  0")
                        .foregroundStyle(valueAvailabe ? .primary : .secondary)
                } maximumValueText: {
                    Text("100 ")
                        .foregroundStyle(valueAvailabe ? .primary : .secondary)
                }
                .frame(width: 140, height: 140)
                Spacer()
            }
            .padding(.vertical, 16)
            .background(.background)
            .clipShape(RoundedRectangle(cornerRadius: HealthDashboardConstants.gridComponentCornerRadius))
            HStack {
                Text("HEART_HEALTH_DASHBOARD_HEADER")
                    .font(.caption)
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(.secondary)
                Spacer()
            }
                .padding(.horizontal)
        }
    }
    
    @ViewBuilder private var learnMoreSection: some View {
        if let learnMoreText = studyManager.localizedMarkdown(for: "LearnMore", in: .hhdExplainer) {
            Section("Understanding Your Heart Health Score") {
                MarkdownView(document: .init(metadata: [:], blocks: [.markdown(id: nil, rawContents: learnMoreText)]))
            }
        }
    }
    
    private var pastDataSection: some View {
        Section("Past Data") {
            Button {
                isPresentingPastTimedWalkTestResults = true
            } label: {
                HStack {
                    Text("PAST_TIMED_WALKING_RUNNING_TEST_RESULTS_BUTTON_TITLE")
                        .foregroundStyle(.textLabel)
                    Spacer()
                    DisclosureIndicator()
                }
            }
        }
    }
    
    private func makeGridTile(
        for scoreKeyPath: KeyPath<CVHScore, ScoreResult>
    ) -> some View {
        let score = $cvhScore[keyPath: scoreKeyPath]
        return HealthDashboardGridTile(
            title: score.sampleType.displayTitle,
            accessibilityIdentifier: score.sampleType.displayTitle(in: .enUS),
            headerInsets: .init(top: 0, leading: 8, bottom: 0, trailing: 0),
            onTap: {
                scoreResultToExplain = .init(keyPath: scoreKeyPath)
            }
        ) {
            VStack(spacing: 0) {
                ScoreResultGauge(scoreResult: score)
                .frame(width: 80, height: 80)
                .padding(.top, 4)
                .padding(.bottom, -8)
                if let timeRange = score.timeRange, score.scoreAvailable {
                    // - For e.g. Sleep, we might prefer this saying "Today, 7:00" instead of just "7:00" which it would show currently
                    //   (if today's sleep session ended at 07AM), the reason being that the user might confuse the label with meaning that they slept for 7 hours.
                    // - For midnight, we might want to just have "Today" instead of "0:00"?
                    // - For the exersice tile, we might want to have "Last 7 days" instead of "0:00" (which is the end of the range)
                    Text(timeRange.upperBound.shortDescription())
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Tap to learn more…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}


extension HeartHealthDashboard {
    /// The `KeyPaths` into the ``CVHScore`` where we allow manual in-app data entry.
    ///
    /// - Important: Must keep this list up to date with the dashboard config and app requirements!
    private static let cvhKeyPathsWithDataEntryEnabled: Set<KeyPath<CVHScore, ScoreResult>> = [
        \.dietScore,
        \.mentalHealthScore,
        \.bodyMassIndexScore,
        \.bloodLipidsScore,
        \.nicotineExposureScore,
        \.bloodGlucoseScore,
        \.bloodPressureScore
    ]
    
    static func canAddSample(for keyPath: KeyPath<CVHScore, ScoreResult>) -> Bool {
        cvhKeyPathsWithDataEntryEnabled.contains(keyPath)
    }
    
    
    @available(*, deprecated)
    static func addSampleSheet(for keyPath: KeyPath<CVHScore, ScoreResult>) -> some View {
        AddSampleSheet(keyPath: keyPath)
    }
}


extension HeartHealthDashboard {
    struct AddSampleSheet: View {
        @AccountFeatureFlagQuery(.init(sources: [
            .launchOption(.dashboardDataEntryUsesQuestionnaires)
        ]))
        private var preferQuestionnaires
        
        let keyPath: KeyPath<CVHScore, ScoreResult>
        
        var body: some View {
            switch keyPath {
            case \.nicotineExposureScore:
                HealthDashboardQuestionnaireView(namedInStudyBundle: "NicotineExposure")
            case \.dietScore:
                HealthDashboardQuestionnaireView(namedInStudyBundle: "Diet")
            case \.mentalHealthScore:
                HealthDashboardQuestionnaireView(namedInStudyBundle: "WHO5")
            case \.bodyMassIndexScore:
                if preferQuestionnaires {
                    HealthDashboardQuestionnaireView(.bmi)
                } else {
                    NavigationStack {
                        SaveBMISampleView()
                    }
                }
            case \.bloodLipidsScore:
                if preferQuestionnaires {
                    Text(verbatim: "TODO") // TODO
                } else {
                    NavigationStack {
                        SaveQuantitySampleView(sampleType: MHCQuantitySampleType.custom(.bloodLipids))
                    }
                }
            case \.bloodGlucoseScore:
                if preferQuestionnaires {
                    Text(verbatim: "TODO") // TODO
                } else {
                    NavigationStack {
                        SaveQuantitySampleView(sampleType: MHCQuantitySampleType.healthKit(.bloodGlucose))
                    }
                }
            case \.bloodPressureScore:
                if preferQuestionnaires {
                    Text(verbatim: "TODO") // TODO
                } else {
                    NavigationStack {
                        SaveBloodPressureSampleView()
                    }
                }
            default:
                EmptyView()
            }
        }
    }
}


//private struct TmpQuestionnaireDataEntrySheet: View {
//    @Environment(\.dismiss) private var dismiss
//    @Environment(MyHeartCountsStandard.self) private var standard
//    
//    private let r4Questionnaire: ModelsR4::Questionnaire
//    private let speziQuestionnaire: Result<SpeziQuestionnaire::Questionnaire, any Error>
//    @State private var viewState: ViewState = .idle
//    
//    var body: some View {
//        switch speziQuestionnaire {
//        case .success(let questionnaire):
//            QuestionnaireSheet(questionnaire, completionStepConfig: .disable) { result in
//                switch result {
//                case .cancelled:
//                    break
//                case .completed(let responses):
//                    do {
//                        let fhirResponse = try ModelsR4::QuestionnaireResponse(responses)
//                        await standard.add(fhirResponse)
//                    } catch {
//                        viewState = .error(AnyLocalizedError(error: error))
//                    }
//                }
//                dismiss()
//            }
//            .viewStateAlert(state: $viewState)
//        case .failure(let error):
//            ContentUnavailableView(
//                "Unable to load questionnaire" as String,
//                systemSymbol: .xmarkOctagon,
//                description: Text(String(describing: error))
//            )
//        }
//    }
//    
//    init(_ questionnaire: ModelsR4::Questionnaire) {
//        r4Questionnaire = questionnaire
//        speziQuestionnaire = Result {
//            try .init(questionnaire)
//        }
//    }
//}


private struct HealthDashboardQuestionnaireView: View {
    private enum QuestionnaireSelector {
        case studyBundleResource(name: String)
        case direct(ModelsR4.Questionnaire)
    }
    
    private struct Questionnaires {
        let fhir: Result<ModelsR4.Questionnaire, any Error>
        let spezi: Result<SpeziQuestionnaire.Questionnaire, any Error>
    }
    
    // swiftlint:disable attributes
    @Environment(\.dismiss) private var dismiss
    @Environment(MyHeartCountsStandard.self) private var standard
    @Environment(StudyManager.self) private var studyManager
    @AccountFeatureFlagQuery(.useNewQuestionnaireUI) private var useNewUI
    // swiftlint:enable attributes
    
    private let selector: QuestionnaireSelector
    @State private var questionnaires: Questionnaires?
    
    var body: some View {
        Group {
            if let questionnaires {
                view(for: questionnaires)
            } else {
                ProgressView("Loading…" as String)
            }
        }
        .task {
            questionnaires = loadQuestionnaire()
        }
    }
    
    init(namedInStudyBundle name: String) {
        selector = .studyBundleResource(name: name)
    }
    
    init(_ questionnaire: ModelsR4.Questionnaire) {
        selector = .direct(questionnaire)
    }
    
    
    private func loadQuestionnaire() -> Questionnaires {
        switch selector {
        case .studyBundleResource(let name):
            guard let studyBundle = studyManager.studyEnrollments.first?.studyBundle,
                  let fhir = studyBundle.questionnaire(named: name, in: studyManager.preferredLocale) else {
                let error = NSError(localizedDescription: "Unable to find Questionnaire")
                return Questionnaires(
                    fhir: .failure(error),
                    spezi: .failure(error)
                )
            }
            return Questionnaires(
                fhir: .success(fhir),
                spezi: Result { try SpeziQuestionnaire.Questionnaire(fhir) }
            )
        case .direct(let fhir):
            return Questionnaires(
                fhir: .success(fhir),
                spezi: Result { try SpeziQuestionnaire.Questionnaire(fhir) }
            )
        }
    }
    
    @ViewBuilder
    private func view(for questionnaires: Questionnaires) -> some View {
        if useNewUI {
            switch questionnaires.spezi {
            case .success(let questionnaire):
                QuestionnaireSheet(questionnaire, completionStepConfig: .disable) { result in
                    switch result {
                    case .completed(let responses):
                        do {
                            let fhirResponse = try ModelsR4.QuestionnaireResponse(responses)
                            await standard.add(fhirResponse, for: questionnaires.fhir.value)
                        } catch {
                            logger.error("Unable to create FHIR questionnaire response")
                            assertionFailure()
                        }
                    case .cancelled:
                        break
                    }
                    dismiss()
                }
            case .failure(let error):
                noQuestionnaireErrorView(for: error)
            }
        } else {
            switch questionnaires.fhir {
            case .success(let questionnaire):
                QuestionnaireView(questionnaire: questionnaire) { result in
                    switch result {
                    case .completed(let response):
                        await standard.add(response, for: questionnaire)
                    case .cancelled, .failed:
                        break
                    }
                    dismiss()
                }
            case .failure(let error):
                noQuestionnaireErrorView(for: error)
            }
        }
    }
    
    private func noQuestionnaireErrorView(for error: any Error) -> some View {
        ContentUnavailableView(
            "Unable to load questionnaire" as String,
            systemSymbol: .xmarkOctagon,
            description: Text(String(describing: error))
        )
    }
}
