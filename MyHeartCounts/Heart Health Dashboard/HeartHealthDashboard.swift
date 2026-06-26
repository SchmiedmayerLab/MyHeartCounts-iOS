//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

// swiftlint:disable file_types_order

import Foundation
import MHCStudyDefinition
import MyHeartCountsShared
import SFSafeSymbols
import SpeziFoundation
import SpeziHealthKit
import SpeziHealthKitUI
import SpeziQuestionnaireLegacy
import SpeziStudy
import SpeziViews
import SwiftUI


struct HeartHealthDashboard: View {
    private struct MetricDescriptor: Identifiable {
        let keyPath: KeyPath<CVHScore, ScoreResult>
        var id: ObjectIdentifier { .init(keyPath) }
    }
    
    // swiftlint:disable attributes
    @Environment(\.colorScheme) private var colorScheme
    @Environment(StudyManager.self) private var studyManager
    // swiftlint:enable attributes
    
    @CVHScore private var cvhScore
    
    @State private var addNewSampleDescriptor: MetricDescriptor?
    @State private var presentedArticle: Article?
    @State private var scoreResultToExplain: MetricDescriptor?
    @State private var isPresentingPastTimedWalkTestResults = false
    
    var body: some View {
        Form {
            healthDashboard
        }
        .sheet(item: $addNewSampleDescriptor) { descriptor in
            Self.addSampleSheet(for: descriptor.keyPath)
        }
        .sheet(item: $presentedArticle) { article in
            ArticleSheet(article: article)
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
        .sheet(isPresented: $isPresentingPastTimedWalkTestResults) {
            NavigationStack {
                PastTimedWalkTestResults()
                    .taskPerformingAnchor()
            }
        }
    }
    
    @ViewBuilder private var healthDashboard: some View {
        HealthDashboard(layout: [
            .large {
                topSection
            },
            .grid(
                sectionTitle: "Score Components",
                footer: "HHD_APPLE_WATCH_REQUIRED_FOOTER"
            ) {
                switch $cvhScore.preferredExerciseMetric {
                case .exerciseMinutes:
                    makeGridComponent(for: \.physicalExerciseScore)
                case .stepCount:
                    makeGridComponent(for: \.stepCountScore)
                }
                makeGridComponent(for: \.sleepHealthScore)
                makeGridComponent(for: \.dietScore)
                makeGridComponent(for: \.mentalHealthScore)
                makeGridComponent(for: \.bloodPressureScore)
                makeGridComponent(for: \.bloodLipidsScore)
                makeGridComponent(for: \.bloodGlucoseScore)
                makeGridComponent(for: \.bodyMassIndexScore)
                makeGridComponent(for: \.nicotineExposureScore)
            }
        ])
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
                        .foregroundStyle(colorScheme.textLabelForegroundStyle)
                    Spacer()
                    DisclosureIndicator()
                }
            }
        }
    }
    
    private func makeGridComponent(
        for scoreKeyPath: KeyPath<CVHScore, ScoreResult>
    ) -> HealthDashboardLayout.GridComponent {
        let score = $cvhScore[keyPath: scoreKeyPath]
        return .custom(
            title: score.sampleType.displayTitle,
            accessibilityIdentifier: score.sampleType.displayTitle(in: .enUS),
            headerInsets: .init(top: 0, leading: 8, bottom: 0, trailing: 0)
        ) {
            VStack(spacing: 0) {
                ScoreResultGauge(scoreResult: score)
                .frame(width: 80, height: 80)
                .padding(.top, 4)
                .padding(.bottom, -8)
                if let timeRange = score.timeRange, score.scoreAvailable {
                    Text(timeRange.upperBound.shortDescription())
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Tap to learn more…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        } onTap: {
            scoreResultToExplain = .init(keyPath: scoreKeyPath)
        }
    }
    
    // periphery:ignore - API
    private func addNewSample(for keyPath: KeyPath<CVHScore, ScoreResult>) {
        if Self.canAddSample(for: keyPath) {
            addNewSampleDescriptor = .init(keyPath: keyPath)
        }
    }
}


extension HeartHealthDashboard {
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
    
    
    static func addSampleSheet(for keyPath: KeyPath<CVHScore, ScoreResult>) -> some View {
        NavigationStack {
            switch keyPath {
            case \.nicotineExposureScore:
                HealthDashboardQuestionnaireView(questionnaireName: "NicotineExposure")
            case \.dietScore:
                HealthDashboardQuestionnaireView(questionnaireName: "Diet")
            case \.mentalHealthScore:
                HealthDashboardQuestionnaireView(questionnaireName: "WHO5")
            case \.bodyMassIndexScore:
                SaveBMISampleView()
            case \.bloodLipidsScore:
                SaveQuantitySampleView(sampleType: MHCQuantitySampleType.custom(.bloodLipids))
            case \.bloodGlucoseScore:
                SaveQuantitySampleView(sampleType: MHCQuantitySampleType.healthKit(.bloodGlucose))
            case \.bloodPressureScore:
                SaveBloodPressureSampleView()
            default:
                EmptyView()
            }
        }
    }
}


private struct HealthDashboardQuestionnaireView: View {
    @Environment(MyHeartCountsStandard.self)
    private var standard
    
    @Environment(StudyManager.self)
    private var studyManager
    
    @Environment(\.dismiss)
    private var dismiss
    
    let questionnaireName: String
    @State private var questionnaire: ModelsR4::Questionnaire?
    
    var body: some View {
        Group {
            if let questionnaire {
                QuestionnaireView(questionnaire: questionnaire) { result in
                    switch result {
                    case .completed(let response):
                        await standard.add(response, for: questionnaire)
                    case .cancelled, .failed:
                        break
                    }
                    dismiss()
                }
            } else {
                ContentUnavailableView("Unable to find Questionnaire", systemSymbol: .exclamationmarkTriangle) // ???
            }
        }
        .task {
            loadQuestionnaire()
        }
    }
    
    private func loadQuestionnaire() {
        guard let studyBundle = studyManager.studyEnrollments.first?.studyBundle else {
            return
        }
        questionnaire = studyBundle.questionnaire(named: questionnaireName, in: studyManager.preferredLocale)
    }
}
