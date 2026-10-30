//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveAccount
import GroveFoundation
import MHCStudyDefinition
@testable import MyHeartCounts
import Testing


@Suite
@MainActor
struct StudyVariantTests {
    @Test(arguments: StudyVariant.allCases)
    func persistenceRestoresVariantAndBackendWithoutAccount(variant: StudyVariant) throws {
        try withPreferences { prefs in
            let config = DeferredConfigLoading.StudyConfiguration(firebaseConfig: .region(.unitedStates), studyVariant: variant)
            try config.persist(in: prefs)
            try config.persist(in: prefs)

            let restored = try DeferredConfigLoading.StudyConfiguration(
                firebaseConfig: #require(prefs[.enrolledFirebaseConfig]),
                studyVariant: #require(prefs[.enrolledStudyVariant])
            )
            #expect(restored.firebaseConfig == .region(.unitedStates))
            #expect(restored.studyVariant == variant)
        }
    }

    @Test(arguments: StudyVariant.allCases)
    func persistedVariantCannotChange(variant: StudyVariant) throws {
        try withPreferences { prefs in
            let config = DeferredConfigLoading.StudyConfiguration(firebaseConfig: .region(.unitedStates), studyVariant: variant)
            try config.persist(in: prefs)
            let other: StudyVariant = variant == .stanford ? .imperial : .stanford

            #expect(throws: DeferredConfigLoading.StudyVariantError.mismatch(expected: variant, actual: other)) {
                try config.selectStudyVariant(other, enrolledVariant: prefs[.enrolledStudyVariant])
            }
            try config.selectStudyVariant(variant, enrolledVariant: prefs[.enrolledStudyVariant])
            #expect(config.studyVariant == variant)
            #expect(prefs[.enrolledStudyVariant] == variant)
            #expect(prefs[.enrolledFirebaseConfig] == .region(.unitedStates))
        }
    }

    @Test
    func selectionCanAdoptAccountVariantBeforeEnrollment() throws {
        try withPreferences { prefs in
            let config = DeferredConfigLoading.StudyConfiguration(firebaseConfig: .region(.unitedStates), studyVariant: .stanford)
            try config.selectStudyVariant(.imperial, enrolledVariant: prefs[.enrolledStudyVariant])

            #expect(config.studyVariant == .imperial)
            #expect(config.firebaseConfig == .region(.unitedStates))
            #expect(prefs[.enrolledStudyVariant] == nil)
            #expect(prefs[.enrolledFirebaseConfig] == nil)
        }
    }

    @Test
    func conflictingPersistencePreservesSavedConfiguration() throws {
        try withPreferences { prefs in
            let enrolled = DeferredConfigLoading.StudyConfiguration(firebaseConfig: .region(.unitedStates), studyVariant: .stanford)
            try enrolled.persist(in: prefs)
            let conflicting = DeferredConfigLoading.StudyConfiguration(firebaseConfig: .region(.unitedKingdom), studyVariant: .imperial)

            #expect(throws: DeferredConfigLoading.StudyVariantError.mismatch(expected: .stanford, actual: .imperial)) {
                try conflicting.persist(in: prefs)
            }
            #expect(prefs[.enrolledStudyVariant] == .stanford)
            #expect(prefs[.enrolledFirebaseConfig] == .region(.unitedStates))
        }
    }

    @Test
    func onlyLegacyEnrolledAccountsDefaultToStanford() {
        var details = AccountDetails()
        #expect(details.existingStudyVariant == nil)

        details.dateOfEnrollment = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(details.existingStudyVariant == .stanford)
    }

    @Test(arguments: StudyVariant.allCases)
    func explicitAccountVariantTakesPrecedence(variant: StudyVariant) {
        var details = AccountDetails()
        details.studyVariant = variant
        #expect(details.existingStudyVariant == variant)

        details.dateOfEnrollment = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(details.existingStudyVariant == variant)
    }

    private func withPreferences(_ body: (LocalPreferencesStore) throws -> Void) throws {
        let suiteName = "StudyVariantTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(LocalPreferencesStore(defaults: defaults))
    }
}
