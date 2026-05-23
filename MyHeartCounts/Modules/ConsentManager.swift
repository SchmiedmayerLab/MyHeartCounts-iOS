//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import FirebaseStorage
import Foundation
import Spezi
import SpeziAccount
import SpeziFoundation
import SpeziLocalization
import SpeziStudy
import SwiftUI


@Observable
final class ConsentManager: Module, EnvironmentAccessible, @unchecked Sendable {
    // swiftlint:disable attributes
    @ObservationIgnored @Dependency(StudyBundleLoader.self) private var studyBundleLoader
    @ObservationIgnored @Dependency(Account.self) private var account: Account?
    @ObservationIgnored @Dependency(StudyManager.self) private var studyManager
    // swiftlint:enable attributes
    
    @MainActor private(set) var needsToSignNewConsentVersion = false
    
    nonisolated init() {}
    
    func configure() {
        Task {
            await doUpdate()
        }
    }
    
    @MainActor
    private func doUpdate() async {
        let studyBundle = withObservationTracking {
            studyBundleLoader.studyBundle?.value
        } onChange: { [weak self] in
            Task {
                await self?.doUpdate()
            }
        }
        guard LocalPreferencesStore.standard[.onboardingFlowComplete] else {
            return
        }
        guard !needsToSignNewConsentVersion else {
            return
        }
        guard let studyBundle else {
            return
        }
        guard let accountDetails = account?.details else {
            return
        }
        guard let consentFile = studyBundle.studyDefinition.metadata.consentFileRef,
              let consentText = studyBundle.consentText(
                for: consentFile,
                in: studyManager.preferredLocale,
                using: .requirePerfectMatch,
                fallbackLocale: studyManager.defaultLanguageFallbackLocale
              ),
              let consentVersion = (try? MarkdownDocument.Metadata(parsing: consentText))?.version else {
                  return
        }
        if let lastSignedVersion = accountDetails.lastSignedConsentVersion.flatMap(Version.init) {
            needsToSignNewConsentVersion = consentVersion.isGreaterThan(lastSignedVersion, upFrom: .minor)
        } else {
            // we're unable to get the most recent signed, so we'll make the user re-sign it
//            await MainActor.run {
//                self.needsToSignNewConsentVersion = true
//            }
        }
    }
}


extension StudyManager {
    var defaultLanguageFallbackLocale: LocalizationKey {
        guard let region = preferredLocale.region else {
            // unreachable in regular usage bc we always set a region (based on the firebase config) when loading the module.
            // only reachable when the firebase config is manually overwritten to point directly to a plist file.
            return .enUS
        }
        return switch region {
        case .unitedStates, .unitedKingdom:
            LocalizationKey(language: .init(identifier: "en"), region: region)
        default:
            // unreachable bc we currently only support the regions listed above.
            .enUS
        }
    }
}


extension Version {
    /// A component of a version.
    public enum Component {
        /// The major component
        case major
        /// The minor component
        case minor
        /// The patch component
        case patch
    }
    
    // periphery:ignore - API
    /// Determines if the version is equal to another version, up to the specified component.
    @inlinable
    public func isEqual(to other: Version, downTo component: Component) -> Bool {
        switch component {
        case .major:
            self.major == other.major
        case .minor:
            self.major == other.major && self.minor == other.minor
        case .patch:
            self.major == other.major && self.minor == other.minor && self.patch == other.patch
        }
    }
    
    /// Determines if the version is greater than another version, starting at the specified component.
    @inlinable
    public func isGreaterThan(_ other: Version, upFrom component: Component) -> Bool {
        switch component {
        case .major:
            self.major > other.major
        case .minor:
            isGreaterThan(other, upFrom: .major) || self.major == other.major && self.minor > other.minor
        case .patch:
            isGreaterThan(other, upFrom: .minor) || self.minor == other.minor && self.patch > other.patch
        }
    }
}
