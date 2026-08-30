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
}
