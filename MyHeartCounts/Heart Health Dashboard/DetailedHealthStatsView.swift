//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

// swiftlint:disable file_types_order attributes

import Charts
import Foundation
import MHCStudyDefinition
import MyHeartCountsShared
import SFSafeSymbols
import SpeziFoundation
import SpeziHealthKit
import SpeziHealthKitUI
import SpeziStudy
import SpeziViews
import SwiftUI


struct DetailedHealthStatsView: View {
    private enum RecentValuesChartConfig {
        /// no chart
        case disabled
        /// chart
        case enabled(timeRange: HealthKitQueryTimeRange)
    }
    
    @Environment(StudyManager.self) private var studyManager
    @State private var chartTimeRange: ChartTimeRange = .lastNumDays(14)
    
    @CVHScore private var cvhScore
    @AccountFeatureFlagQuery(.isDebugModeEnabled) private var debugModeEnabled
    @State private var isPresentingAddSampleSheet = false
    
    private let keyPath: KeyPath<CVHScore, ScoreResult>
    private var sampleType: MHCSampleType {
        scoreResult.sampleType
    }
    private var scoreResult: ScoreResult {
        _cvhScore[keyPath: keyPath]
    }
    
    var body: some View {
        Form {
            Section {
                scoreResultBasedTopSection(for: scoreResult)
            }
            .listRowInsets(.zero)
            .listRowBackground(Color.clear)
            recentValuesChart(recentValuesChartConfig)
            if showScoreExplainerSection {
                scoreResultExplainer(for: scoreResult)
            }
            if let explainer = explainerText(for: sampleType) {
                let document = (try? MarkdownDocument(processing: explainer))
                    ?? MarkdownDocument(metadata: [:], blocks: [.markdown(id: nil, rawContents: explainer)])
                FurtherReadingSection(
                    title: "About \(sampleType.displayTitle)",
                    document: document
                )
            }
            if debugModeEnabled, case let .custom(sampleType) = sampleType {
                Section("Debug") {
                    NavigationLink("All Samples") {
                        BrowseFirestoreSamplesView(sampleType: sampleType)
                    }
                }
            }
        }
        .navigationTitle(sampleType.displayTitle)
        .toolbar {
            if HeartHealthDashboard.canAddSample(for: keyPath) {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add Data", systemSymbol: .plus) {
                        isPresentingAddSampleSheet = true
                    }
                    .buttonStyleGlassProminent()
                }
            }
        }
        .sheet(isPresented: $isPresentingAddSampleSheet) {
            HeartHealthDashboard.addSampleSheet(for: keyPath)
        }
    }
    
    
    private var recentValuesChartConfig: RecentValuesChartConfig {
        switch keyPath {
        case \.nicotineExposureScore, \.dietScore:
            .disabled
        default:
            .enabled(timeRange: .init(chartTimeRange))
        }
    }
    
    private var showScoreExplainerSection: Bool {
        switch keyPath {
        case \.mentalHealthScore:
            // we disable this for the mental health score, bc the values go from 0 to 100, which is already indicated in the gauge,
            // and it'd only show a single row, which looks weird.
            false
        default:
            true
        }
    }
    
    
    init(_ keyPath: KeyPath<CVHScore, ScoreResult>) {
        self.keyPath = keyPath
    }
    
    
    @ViewBuilder
    private func recentValuesChart(_ config: RecentValuesChartConfig) -> some View { // swiftlint:disable:this function_body_length
        switch config {
        case .disabled:
            EmptyView()
        case .enabled(let timeRange):
            let dataSource = { () -> HealthDashboardLayout.DataSource? in
                switch sampleType {
                case .healthKit(let proxy):
                    return .healthKit(proxy)
                case .custom(let sampleType):
                    return .firebase(sampleType)
                }
            }()
            Section {
                if let dataSource {
                    // Note: we're creating a chart config here, but depending on the specific sample type it might end up getting discarded
                    // (eg: if the sample type is sleepAnalyis, in which case it's not something we display via the normal chart)
                    let chartConfig = { () -> HealthDashboardLayout.ChartConfig in
                        switch sampleType {
                        case .healthKit(.quantity(.stepCount)):
                            return .init(chartType: .bar, aggregationInterval: .day)
                        case .healthKit(.quantity(let sampleType)):
                            return .default(for: sampleType, in: timeRange)
                        case .healthKit:
                            return .init(chartType: .line(), defaultAggregationIntervalFor: timeRange)
                        case .custom(.bloodLipids), .custom(.dietMEPAScore), .custom(.nicotineExposure), .custom(.mentalWellbeingScore):
                            return .init(chartType: .line(), defaultAggregationIntervalFor: timeRange)
                        case .custom:
                            return .init(chartType: .line(), defaultAggregationIntervalFor: timeRange)
                        }
                    }()
                    healthDashboardComponentView(
                        for: .init(
                            dataSource: dataSource,
                            timeRange: timeRange,
                            style: .chart(chartConfig),
                            enableSelection: false
                        ),
                        withSize: .large,
                        accessory: .timeRangeSelector($chartTimeRange)
                    )
                    .padding(.horizontal)
                    .healthStatsChartHoverHighlightEnabled()
                    .environment(\.isRecentValuesViewInDetailedStatsSheet, true)
                } else {
                    HStack {
                        Spacer()
                        Text("Unable to load data")
                        Spacer()
                    }
                }
            }
            .frame(height: 220)
            .listRowInsets(.zero)
        }
    }
    
    
    @ViewBuilder
    private func scoreResultBasedTopSection(for scoreResult: ScoreResult) -> some View {
        let spacing: Double = 24
        GeometryReader { geometry in
            let gaugePartWidth = (geometry.size.width - spacing) * 0.37
            let leftPartWidth = geometry.size.width - spacing - gaugePartWidth
            HStack(spacing: spacing / 2 - 1) {
                MostRecentValue(scoreResult)
                    .frame(width: leftPartWidth, alignment: .leading)
                Divider()
                    .frame(width: 1)
                ScoreResultGauge(scoreResult: scoreResult)
                    .frame(width: 90, height: 90)
                    .frame(width: gaugePartWidth, alignment: .center)
            }
        }
        .frame(height: 120)
        .padding(.horizontal)
    }
    
    private func scoreResultExplainer(for scoreResult: ScoreResult) -> some View {
        ScoreExplanationSection(scoreResult: scoreResult)
            .listRowBackground(Color.clear)
    }
}


private struct MostRecentValue: View {
    private struct Component {
        let value: String
        let unit: String?
        
        init(value: String, unit: String?) {
            self.value = value
            self.unit = unit
        }
        
        init(value: String, unit: HKUnit?) {
            self.init(value: value, unit: unit == .count() ? nil : unit?.unitString)
        }
    }
    
    @Environment(\.locale) private var locale
    @Environment(\.calendar) private var cal
    
    private let scoreResult: ScoreResult
    private let components: [Component]
    private let valueAccessibilityDesc: LocalizedStringResource
    
    var body: some View {
        VStack(alignment: .leading) {
            Text(scoreResult.title)
                .foregroundStyle(.secondary)
            valueDisplay
                .font(.headline)
            if let timeRange = scoreResult.timeRange {
                Text(timeRange.upperBound.shortDescription())
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityRepresentation {
            if components.isEmpty {
                Text(valueAccessibilityDesc) // will be "No Recent Data" in this case.
            } else {
                Text("\(scoreResult.title): \(valueAccessibilityDesc)")
            }
        }
    }
    
    @ViewBuilder private var valueDisplay: some View {
        if components.isEmpty {
            Text("No Data")
                .foregroundStyle(.secondary)
        } else {
            HStack(alignment: .bottom) {
                ForEach(Array(components.indices), id: \.self) { idx in
                    let component = components[idx]
                    HStack(spacing: 2) {
                        Text(component.value)
                            .bold()
                            .monospacedDigit()
                        if let unit = component.unit {
                            Text(unit)
                                .textScale(.secondary)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
    
    private init(scoreResult: ScoreResult, components: [Component], valueAccessibilityDesc: LocalizedStringResource) {
        self.scoreResult = scoreResult
        self.components = components
        self.valueAccessibilityDesc = valueAccessibilityDesc
    }
    
    init(_ scoreResult: ScoreResult) {
        switch scoreResult.inputValue {
        case let value as any BinaryFloatingPoint:
            self.init(value, scoreResult: scoreResult)
        case let value as BloodPressureMeasurement:
            self.init(
                scoreResult: scoreResult,
                components: [
                    .init(
                        value: "\(value.systolic)/\(value.diastolic)",
                        unit: .millimeterOfMercury()
                    )
                ],
                valueAccessibilityDesc: "\(value.systolic) over \(value.diastolic)"
            )
        case .some(let value):
            let valueDesc = switch value {
            case let value as any CustomLocalizedStringResourceConvertible:
                String(localized: value.localizedStringResource)
            default:
                String(describing: value)
            }
            self.init(
                scoreResult: scoreResult,
                components: [.init(value: valueDesc, unit: scoreResult.sampleType.displayUnit)],
                valueAccessibilityDesc: { () -> LocalizedStringResource in
                    if let unit = scoreResult.sampleType.displayUnit, unit != .count() {
                        "\(valueDesc) \(unit.unitString)"
                    } else {
                        "\(valueDesc)"
                    }
                }()
            )
        case .none:
            self.init(scoreResult: scoreResult, components: [], valueAccessibilityDesc: "No recent data")
        }
    }
    
    
    private init<V: BinaryFloatingPoint>(_ value: V, scoreResult: ScoreResult) {
        self.scoreResult = scoreResult
        let sampleType = scoreResult.sampleType
        switch sampleType {
        case .healthKit(.category(.sleepAnalysis)):
            let (hours, minutes) = Int(value * 60).quotientAndRemainder(dividingBy: 60)
            components = Array {
                if hours > 0 {
                    Component(value: String(hours), unit: .hour())
                }
                if minutes > 0 {
                    Component(value: String(minutes), unit: .minute())
                }
            }
            valueAccessibilityDesc = "\(hours) hours and \(minutes) minutes"
        default:
            let value = value.formatted(FloatingPointFormatStyle<V>().precision(.fractionLength(...2)))
            components = [
                Component(value: value, unit: sampleType.displayUnit)
            ]
            valueAccessibilityDesc = if let unit = sampleType.displayUnit, unit != .count() {
                 "\(value) \(unit.unitString)"
            } else {
                "\(value)"
            }
        }
    }
}


private struct FurtherReadingSection: View {
    private let title: LocalizedStringResource
    private let document: MarkdownDocument
    private let links: [URL]
    
    var body: some View {
        Section(title) {
            VStack(alignment: .leading) {
                MarkdownView(document: document)
                    .padding(.vertical, 5)
            }
            ForEach(Array(links.indices), id: \.self) { idx in
                makeLinkButton(idx == links.startIndex ? "Learn More" : nil, for: links[idx])
            }
        }
    }
    
    init(title: LocalizedStringResource, document: MarkdownDocument) {
        self.title = title
        self.document = document
        self.links = document.metadata
            .filter { $0.key.starts(with: "link") }
            .sorted(using: KeyPathComparator(\.key))
            .compactMap { try? URL($0.value, strategy: .url) }
    }
    
    private func makeLinkButton(_ title: LocalizedStringResource?, for url: URL) -> some View {
        Link2(url) {
            HStack {
                if let title {
                    Text(title)
                }
                Spacer()
                if let host = url.host() {
                    // drop the initial "www.", if present
                    let host = if let range = host.range(of: "www."), range.lowerBound == host.startIndex {
                        host.replacingCharacters(in: range, with: "")
                    } else {
                        host
                    }
                    Text(host)
                        .foregroundStyle(.textLabel.secondary)
                }
                Image(systemSymbol: .safari)
                    .accessibilityLabel("Open In Browser")
            }
            .contentShape(Rectangle())
        }
    }
}


extension DetailedHealthStatsView {
    private func explainerText(for sampleType: MHCSampleType) -> String? { // swiftlint:disable:this cyclomatic_complexity
        let imp = { (key: String) -> String? in
            studyManager.localizedMarkdown(for: key, in: .hhdExplainer)
        }
        return switch sampleType {
        case .custom(.dietMEPAScore):
            imp("DietScore")
        case .custom(.mentalWellbeingScore):
            imp("MentalWellbeing")
        case .custom(.bloodLipids):
            imp("BloodLipids")
        case .custom(.nicotineExposure):
            imp("NicotineExposure")
        case .healthKit(.quantity(.bodyMassIndex)):
            imp("BMI")
        case .healthKit(.quantity(.appleExerciseTime)):
            imp("ExerciseMinutes")
        case .healthKit(.quantity(.stepCount)):
            imp("StepCount")
        case .healthKit(.quantity(.bloodGlucose)):
            imp("BloodGlucose")
        case .healthKit(.category(.sleepAnalysis)):
            imp("Sleep")
        case .healthKit(.correlation(.bloodPressure)):
            imp("BloodPressure")
        default:
            nil
        }
    }
}


extension StudyManager {
    func localizedMarkdown(for filename: String, in category: StudyBundle.FileReference.Category) -> String? {
        let fileRef = StudyBundle.FileReference(category: category, filename: filename, fileExtension: "md")
        guard let studyBundle = studyEnrollments.first?.studyBundle, let url = studyBundle.resolve(fileRef, in: preferredLocale) else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}


private struct BrowseFirestoreSamplesView: View {
    private let sampleType: CustomQuantitySampleType
    @MHCFirestoreQuery<QuantitySample> private var samples: [QuantitySample]
    
    var body: some View {
        Form {
            List(samples) { sample in
                NavigationLink {
                    Form {
                        LabeledContent { Text(verbatim: "id") } label: { Text(sample.id.uuidString) }
                        LabeledContent { Text(verbatim: "sampleType") } label: { Text(sample.sampleType.displayTitle) }
                        LabeledContent { Text(verbatim: "unit") } label: { Text(sample.unit.unitString) }
                        LabeledContent { Text(verbatim: "value") } label: { Text(sample.value, format: .number) }
                        LabeledContent { Text(verbatim: "startDate") } label: { Text(sample.startDate, format: .dateTime) }
                        LabeledContent { Text(verbatim: "endDate") } label: { Text(sample.endDate, format: .dateTime) }
                    }
                } label: {
                    HStack {
                        Text(sample.startDate, format: .dateTime)
                        Spacer()
                        Text(sample.valueAndUnitDescription())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle(sampleType.displayTitle)
    }
    
    init(sampleType: CustomQuantitySampleType) {
        self.sampleType = sampleType
        _samples = .init(sampleType: sampleType, timeRange: .ever)
    }
}
