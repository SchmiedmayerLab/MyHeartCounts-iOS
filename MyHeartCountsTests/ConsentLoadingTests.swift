//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

// swiftlint:disable line_length

import Foundation
import GroveFoundation
import GroveLocalization
import GroveStudy
import GroveStudyDefinition
@testable import MyHeartCounts
import Testing
import UniformTypeIdentifiers


@Suite
struct ConsentLoadingTests {
    @Test
    func consentLoading() throws {
        let studyBundle = try makeStudyBundle()
        func fetchConsent(for locale: Locale) -> String? {
            studyBundle.bundle.consentText(
                for: .consent,
                in: locale,
                using: .requirePerfectMatch,
                fallbackLocale: nil
            )
        }
        
        func expectAllEqual(to expectedText: String, _ locales: [Locale], _ sourceLocation: SourceLocation = #_sourceLocation) throws {
            let results = try locales.map { locale in
                try #require(fetchConsent(for: locale), sourceLocation: sourceLocation)
            }
            #expect(Set(results).count == 1, "Got non-matching results: \(results)", sourceLocation: sourceLocation)
            #expect(try #require(results.first, sourceLocation: sourceLocation) == expectedText, sourceLocation: sourceLocation)
        }
        
        try expectAllEqual(to: "Hey en-US!", [
            Locale(identifier: "en-US"),
            Locale(languageCode: .english, languageRegion: .unitedStates),
            Locale(language: .init(languageCode: .english, script: nil, region: .unitedStates), region: .unitedStates)
//            Locale(language: .init(languageCode: .english, script: nil, region: nil), region: .unitedStates)
        ])
        try expectAllEqual(to: "Hey es-US!", [
            Locale(identifier: "es-US"),
            Locale(languageCode: .spanish, languageRegion: .unitedStates)
        ])
        try expectAllEqual(to: "Hey en-UK!", [
            Locale(identifier: "en-UK"),
            Locale(identifier: "en-GB"),
            Locale(languageCode: .english, languageRegion: .unitedKingdom),
            Locale(language: .init(languageCode: .english, script: nil, region: .unitedKingdom), region: .unitedKingdom)
//            Locale(language: .init(languageCode: .english, script: nil, region: nil), region: .unitedKingdom)
        ])
    }
}


extension StudyBundle.FileReference {
    fileprivate static let consent = StudyBundle.FileReference(category: .consent, filename: "Consent", fileExtension: "md")
}


extension ConsentLoadingTests {
    @dynamicMemberLookup
    private struct ManagedStudyBundle: ~Copyable {
        let bundle: StudyBundle
        
        subscript<T>(dynamicMember keyPath: KeyPath<StudyBundle, T>) -> T {
            bundle[keyPath: keyPath]
        }
        
        deinit {
            try? FileManager.default.removeItem(at: bundle.bundleUrl)
        }
    }
    
    
    private func makeStudyBundle() throws -> ManagedStudyBundle {
        let bundleUrl = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, conformingTo: .studyBundle)
        let studyBundle = try StudyBundle.writeToDisk(
            at: bundleUrl,
            definition: StudyDefinition(
                studyRevision: 0,
                metadata: .init(
                    id: UUID(),
                    title: [:],
                    explanationText: [:],
                    shortExplanationText: [:],
                    participationCriterion: true,
                    consentFileRef: .consent
                ),
                components: [],
                componentSchedules: []
            ),
            files: [
                try StudyBundle.FileResourceInput(fileRef: .consent, localization: .init(language: .init(identifier: "en"), region: .unitedStates), contents: "Hey en-US!"),
                try StudyBundle.FileResourceInput(fileRef: .consent, localization: .init(language: .init(identifier: "es"), region: .unitedStates), contents: "Hey es-US!"),
                try StudyBundle.FileResourceInput(fileRef: .consent, localization: .init(language: .init(identifier: "en"), region: .unitedKingdom), contents: "Hey en-UK!")
            ]
        )
        return ManagedStudyBundle(bundle: studyBundle)
    }
}
