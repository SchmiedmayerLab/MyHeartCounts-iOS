//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import GroveViews
import SFSafeSymbols
import SwiftUI


/// Explains how the composite CVH score is computed, and offers shortcuts for providing data for those components that don't have any.
///
/// - Note: This view takes plain values instead of using ``CVHScore`` directly, since a second instance would start out empty and then fill up as its queries load.
struct HeartHealthScoreSheet: View {
    /// The components for which the user can manually enter data, ordered from easiest to hardest to provide.
    private static let dataEntryOrder: [KeyPath<CVHScore, ScoreResult>] = [
        \.nicotineExposureScore,
        \.bodyMassIndexScore,
        \.dietScore,
        \.bloodPressureScore,
        \.bloodGlucoseScore,
        \.bloodLipidsScore
    ]
    
    let score: Double?
    let components: [CVHScore.Component]
    /// The title of the dashboard tile that doesn't count toward the score.
    let unscoredTileTitle: String
    
    @State private var componentToAddDataFor: CVHScore.Component?
    
    private var componentsWithData: [CVHScore.Component] {
        components.filter(\.result.scoreAvailable)
    }
    
    private var componentsMissingData: [CVHScore.Component] {
        components.filter { !$0.result.scoreAvailable }
    }
    
    private var enterableComponents: [CVHScore.Component] {
        Self.dataEntryOrder.compactMap { keyPath in
            componentsMissingData.first { $0.keyPath == keyPath }
        }
    }
    
    private var automaticComponents: [CVHScore.Component] {
        componentsMissingData.filter { !HeartHealthDashboard.canAddSample(for: $0.keyPath) }
    }
    
    var body: some View {
        Form {
            headerSection
            calculationSection
            if !componentsWithData.isEmpty {
                componentsWithDataSection
            }
            if !componentsMissingData.isEmpty {
                completeYourScoreSection
            }
        }
        .navigationTitle("Heart Health Score")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                DismissButton()
            }
        }
        .sheet(item: $componentToAddDataFor) { component in
            HeartHealthDashboard.addSampleSheet(for: component.keyPath)
        }
    }
    
    private var headerSection: some View {
        Section {
            VStack(spacing: 8) {
                OverallScoreGauge(score: score)
                Text("Based on \(componentsWithData.count) of \(components.count) score components")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
    }
    
    private var calculationSection: some View {
        Section {
            Text("HHD_SCORE_SHEET_CALCULATION_EXPLAINER")
            Text("Your overall score appears once at least \(CVHScore.minNumComponentsForScore) components have data.")
        } header: {
            Text("How It's Calculated")
        } footer: {
            Text("\(unscoredTileTitle) is shown on your dashboard, but doesn't count toward your overall score.")
        }
    }
    
    private var componentsWithDataSection: some View {
        Section("Components With Data") {
            ForEach(componentsWithData) { component in
                NavigationLink {
                    DetailedHealthStatsView(component.keyPath)
                } label: {
                    LabeledContent(component.result.sampleType.displayTitle) {
                        if let score = component.result.score {
                            Text(Int(score * 100), format: .number)
                        }
                    }
                }
            }
        }
    }
    
    private var completeYourScoreSection: some View {
        Section {
            ForEach(enterableComponents) { component in
                Button {
                    componentToAddDataFor = component
                } label: {
                    LabeledContent {
                        Image(systemSymbol: .plusCircle)
                            .accessibilityLabel("Add Data")
                    } label: {
                        Text(component.result.sampleType.displayTitle)
                            .foregroundStyle(.textLabel)
                        Text(Self.dataEntryHint(for: component.keyPath))
                    }
                }
            }
            ForEach(automaticComponents) { component in
                LabeledContent {
                    EmptyView()
                } label: {
                    Text(component.result.sampleType.displayTitle)
                    Text(Self.dataEntryHint(for: component.keyPath))
                }
            }
        } header: {
            Text("Complete Your Score")
        } footer: {
            Text("HHD_SCORE_SHEET_COMPLETE_FOOTER")
        }
    }
    
    private static func dataEntryHint(for keyPath: KeyPath<CVHScore, ScoreResult>) -> LocalizedStringResource {
        switch keyPath {
        case \.nicotineExposureScore:
            "One question"
        case \.bodyMassIndexScore:
            "Your height and weight"
        case \.dietScore:
            "A questionnaire about your diet"
        case \.bloodPressureScore:
            "Needs a blood pressure reading"
        case \.bloodGlucoseScore:
            "Needs a blood glucose reading"
        case \.bloodLipidsScore:
            "Needs a lab result"
        default:
            "Collected automatically"
        }
    }
}
