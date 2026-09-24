//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveStudyDefinition
import MHCStudyDefinitionExporter
import ModelsR4
@testable import MyHeartCounts
import ResearchKit
import ResearchKitOnFHIR
import Testing


@Suite
final class OtherTests {
    private let tmpDir = URL.temporaryDirectory.appending(
        component: "edu.stanford.MyHeartCounts.Tests_\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    
    let studyBundle: StudyBundle
    
    init() throws {
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let studyBundleUrl = try export(to: tmpDir, as: .package)
        studyBundle = try StudyBundle(bundleUrl: studyBundleUrl)
    }
    
    deinit { // swiftlint:disable:this type_contents_order
        try? FileManager.default.removeItem(at: tmpDir)
    }
    
    @Test
    func fhirQuestionnaireToResearchKitTaskProcessing() throws {
        let nicotineQuestionnaire = try #require(studyBundle.questionnaire(named: "NicotineExposure", in: Locale(identifier: "en_US")))
        let task = try ORKNavigableOrderedTask(questionnaire: nicotineQuestionnaire)
        #expect(task.identifier == nicotineQuestionnaire.url?.value?.url.absoluteString)
        #expect(task.identifier == "https://myheartcounts.stanford.edu/fhir/survey/nicotineExposure")
    }
    
    @Test
    func healthStatsCalculatorDataSourceCoding() throws {
        typealias DataSourceID = HealthKitStatsCalculator.DataSourceID
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            let encoded = try encoder.encode(DataSourceID.healthKit)
            #expect(String(decoding: encoded, as: UTF8.self) == #""com.apple.HealthKit""#)
        }
        do {
            struct Wrapper: Codable {
                let dataSource: DataSourceID
                let value: Int
            }
            let encoded = try encoder.encode(Wrapper(dataSource: .healthKit, value: 12))
            #expect(String(decoding: encoded, as: UTF8.self) == #"{"dataSource":"com.apple.HealthKit","value":12}"#)
        }
        do {
            let entries: [DataSourceID: [Int]] = [
                .healthKit: [1, 2, 3],
                .fitbit: [4, 5, 6]
            ]
            let encoded = try encoder.encode(entries)
            #expect(String(decoding: encoded, as: UTF8.self) == #"{"com.apple.HealthKit":[1,2,3],"fitbit":[4,5,6]}"#)
            let decoded = try JSONDecoder().decode(type(of: entries), from: encoded)
            #expect(decoded == entries)
        }
    }
}


extension HealthKitStatsCalculator.DataSourceID {
    fileprivate static let fitbit = Self(rawValue: "fitbit")
}
