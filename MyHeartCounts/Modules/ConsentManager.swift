//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import FirebaseStorage
import Foundation
@_spi(APISupport) // dynamic module loading
import Grove
import GroveAccount
import class GroveConsent.ConsentDocument
import GroveFoundation
import GroveLocalization
import GroveStudy
import MyHeartCountsShared
import SwiftUI


@Observable
@MainActor
final class ConsentManager: Module, EnvironmentAccessible, Sendable {
    // swiftlint:disable attributes
    @ObservationIgnored @Application(\.grove) private var grove
    @ObservationIgnored @Dependency(StudyBundleLoader.self) private var studyBundleLoader
    @ObservationIgnored @Dependency(Account.self) private var account: Account?
    @ObservationIgnored @Dependency(StudyManager.self) private var studyManager
    // swiftlint:enable attributes
    
    @MainActor var pendingConsentDoc: ConsentDocument?
    
    
    private var isInTestEnvSetup: Bool {
        grove.module(SetupTestEnvironment.self)?.isInSetup ?? false
    }
    
    nonisolated init() {}
    
    func configure() {
        Task {
            await doUpdate()
        }
    }
    
    @MainActor
    private func doUpdate() async {
        let (studyBundle, _) = withObservationTracking {
            (studyBundleLoader.studyBundle?.value, account?.details)
        } onChange: { [weak self] in
            Task {
                await self?.doUpdate()
            }
        }
        guard LocalPreferencesStore.standard[.onboardingFlowComplete], !isInTestEnvSetup else {
            // we never want this to trigger during the regular onboarding, as it could interfere with the flow there.
            return
        }
        guard let studyBundle else {
            return
        }
        guard let doc = try? loadConsentDoc(from: studyBundle) else {
            return
        }
        if let shouldSign = try? shouldSign(doc.metadata) {
            switch shouldSign {
            case .no:
                setPendingDoc(nil)
            case .yes(.signedOldVersion):
                setPendingDoc(doc)
            case .yes(.neverSigned):
                if LaunchOptions[.triggerConsentRenewalIfNeverSigned] {
                    setPendingDoc(doc)
                } else {
                    setPendingDoc(nil)
                }
            }
        }
    }
    
    
    private func setPendingDoc(_ newDoc: ConsentDocument?) {
        switch (pendingConsentDoc, newDoc) {
        case (.none, .none):
            return
        case (.none, _), (.some, .none):
            pendingConsentDoc = newDoc
        case let (.some(old), .some(new)):
            if old == new || old.metadata.version == new.metadata.version {
                return
            } else {
                pendingConsentDoc = new
            }
        }
    }
    
    
    func loadConsentDoc() async throws -> ConsentDocument {
        // NOTE: we need to get the StudyBundle from the StudyBundleLoader, instead of the StudyManager,
        // since the app won't necessarily be already enrolled at this point.
        // (it is if this is a Consent renewal, but not during the initial onboarding...)
        try loadConsentDoc(from: try await studyBundleLoader.update())
    }
    
    func loadConsentDoc(from studyBundle: StudyBundle) throws -> ConsentDocument {
        guard let fileRef = studyBundle.studyDefinition.metadata.consentFileRef,
              let consentText = studyBundle.consentText(
                for: fileRef,
                in: studyManager.preferredLocale,
                using: .requirePerfectMatch,
                fallbackLocale: studyManager.defaultLanguageFallbackLocale
              ) else {
            throw NSError(mhcErrorCode: .unspecified, localizedDescription: "Failed to load doc")
        }
        return try ConsentDocument(
            markdown: consentText,
            initialName: account?.details?.name
        )
    }
}


extension ConsentManager {
    private struct UnableToDetermineShouldSignStatusError: Error {}
    
    enum ShouldSignConsentResult {
        case yes(YesReason)
        case no // swiftlint:disable:this identifier_name
        
        enum YesReason {
            case neverSigned
            case signedOldVersion
        }
    }
    
    /// Determines if the user should be prompted to sign a specific consent document.
    ///
    /// - returns: a boolean indicating whether the user should be asked to sign the supplied consent version.
    /// - throws: if the function was unable to determine the consent state.
    ///     this will typically happen if the app is offline and the last-signed version cannot be determined, or if the input does not contain a valid version.
    ///
    /// - Note: If this function is unsure whether the user already signed the document, or signed a recent enough version of it, it will err on the side of caution and
    ///     rather suggest the user be asked to re-sign the document, than not.
    @MainActor
    func shouldSign(_ documentMetadata: MarkdownDocument.Metadata) throws -> ShouldSignConsentResult {
        guard let accountDetails = account?.details,
              !accountDetails.isIncomplete,
              let docVersion = documentMetadata.version else {
            throw UnableToDetermineShouldSignStatusError()
        }
        guard let lastSignedVersion = accountDetails.lastSignedConsentVersion.flatMap(Version.init) else {
            return .yes(.neverSigned)
        }
        return if docVersion.isGreaterThan(lastSignedVersion, upFrom: .minor) {
            .yes(.signedOldVersion)
        } else {
            .no
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
