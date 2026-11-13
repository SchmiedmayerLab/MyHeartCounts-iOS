//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

// swiftlint:disable type_contents_order file_types_order file_length

import class FirebaseCore.FirebaseOptions
import class FirebaseFirestore.FirestoreSettings
import class FirebaseFirestore.MemoryCacheSettings
import class FirebaseFirestore.PersistentCacheSettings
import Foundation
@_spi(APISupport) // we need to access `GroveAppDelegate.grove`
import Grove
import GroveAccount
import GroveFirebaseAccount
import GroveFirebaseAccountStorage
import GroveFirebaseConfiguration
import GroveFirebaseStorage
import GroveFirestore
import GroveFoundation
import GroveLocalization
import GroveSensorKit
import GroveStudy
import MHCStudyDefinition
import MyHeartCountsShared
import Observation
import OSLog
import SwiftUI
import Synchronization
import UniformTypeIdentifiers


extension LocalPreferenceKeys {
    /// The configuration committed when study enrollment starts, so partially completed enrollment also keeps its backend.
    static let enrolledFirebaseConfig = LocalPreferenceKey<DeferredConfigLoading.FirebaseConfigSelector?>(
        // Preserve the existing storage key and encoding; enrolled users need no preference migration.
        "lastUsedFirebaseConfig",
        default: nil
    )

    /// The enrolled study variant, retained unchanged until the local enrollment is removed.
    static let enrolledStudyVariant = LocalPreferenceKey<StudyVariant?>("enrolledStudyVariant")
}


enum DeferredConfigLoading { // swiftlint:disable:this type_body_length
    fileprivate static let logger = Logger(category: .init("Config"))

    /// The independent backend and study selections used together for this process. Variant changes also update observing views.
    @Observable
    @MainActor
    final class StudyConfiguration { // intentionally a class.
        let firebaseConfig: FirebaseConfigSelector
        private(set) var studyVariant: StudyVariant
        
        init(firebaseConfig: FirebaseConfigSelector, studyVariant: StudyVariant) {
            self.firebaseConfig = firebaseConfig
            self.studyVariant = studyVariant
        }
        
        func selectStudyVariant(_ variant: StudyVariant, enrolledVariant: StudyVariant?) throws {
            if let enrolledVariant, enrolledVariant != variant {
                throw StudyVariantError.mismatch(expected: enrolledVariant, actual: variant)
            }
            studyVariant = variant
        }
        
        func persist(in prefs: LocalPreferencesStore) throws {
            try selectStudyVariant(studyVariant, enrolledVariant: prefs[.enrolledStudyVariant])
            prefs[.enrolledStudyVariant] = studyVariant
            prefs[.enrolledFirebaseConfig] = firebaseConfig
        }
    }

    /// Includes temporary onboarding selections; persisted only when study enrollment starts.
    @MainActor private static var activeConfiguration: StudyConfiguration?

    @MainActor static var activeFirebaseConfig: FirebaseConfigSelector? {
        activeConfiguration?.firebaseConfig
    }

    
    @MainActor static var currentStudyVariant: CurrentStudyVariant {
        if let activeConfiguration {
            .active(activeConfiguration.studyVariant)
        } else if let forced = FeatureFlags.forcedStudyVariant {
            // we dont have an activeConfig yet, but we do have a forced variant pending
            .pending(forced)
        } else {
            .unknown
        }
    }
    
    enum LoadingError: LocalizedError {
        case unableToLoadFirebaseConfigPlist(underlying: (any Error)? = nil)
        /// The main bundle doesn't contain a plist with the specified name.
        case plistNotFoundInBundle(name: String)
        /// The file at the specified path doesn't exist, or isn't a valid Firebase config plist.
        case invalidFirebaseConfigPlist(path: String)
        /// There is no Firebase config for the specified region.
        case unsupportedRegion(Locale.Region)

        var errorDescription: String? {
            switch self {
            case .unableToLoadFirebaseConfigPlist(underlying: nil):
                "Unable to load the app's Firebase config."
            case .unableToLoadFirebaseConfigPlist(underlying: let underlying?):
                "Unable to load the app's Firebase config: \(underlying.localizedDescription)"
            case .plistNotFoundInBundle(let name):
                "Unable to find '\(name).plist' in the app bundle."
            case .invalidFirebaseConfigPlist(let path):
                "The Firebase config at '\(path)' doesn't exist, or isn't a valid plist."
            case .unsupportedRegion(let region):
                "There is no Firebase config for region '\(region.identifier)'."
            }
        }
    }
    
    enum FirebaseConfigSelector: Codable, Equatable, Sendable, LaunchOptionDecodable, CustomStringConvertible {
        /// the firebase config for the specified region should be loaded
        case region(Locale.Region)
        /// the firebase config plist with the specified name should be loaded from the main bundle
        case custom(plistNameInBundle: String)
        /// the firebase config plist at the specified URL should be loaded
        case customUrl(URL)
        
        var description: String {
            switch self {
            case .region(let region):
                "region(\(region))"
            case .custom(let plistNameInBundle):
                "plistInBundle(\(plistNameInBundle))"
            case .customUrl(let url):
                "url(\(url))"
            }
        }
        
        /// Decodes a `FirebaseConfigSelector` from a launch option value
        ///
        /// `--overrideFirebaseConfig region=US`
        /// `--overrideFirebaseConfig plist=GoogleService-Info-Override` (the name of a plist in the main bundle, without its file extension)
        /// `--overrideFirebaseConfig plist=/Users/lukas/Desktop/MHC.plist`
        init(decodingLaunchOption context: LaunchOptionDecodingContext) throws {
            try context.assertNumRawArgs(.equal(1))
            let components = context.rawArgs[0].split(separator: "=")
            guard components.count == 2 else {
                throw LaunchOptionDecodingError.unableToDecode(Self.self, rawValue: context.rawArgs[0])
            }
            switch components[0] {
            case "region":
                let regionIdentifier = String(components[1])
                guard Locale.Region.isoRegions.contains(where: { $0.identifier == regionIdentifier }) else {
                    throw LaunchOptionDecodingError.unableToDecode(Self.self, rawValue: context.rawArgs[0])
                }
                self = .region(Locale.Region(regionIdentifier))
            case "plist":
                let location = String(components[1])
                if location.starts(with: "https://") {
                    // https --> treat as internet url (which isn't allowed)
                    throw LaunchOptionDecodingError.unableToDecode(Self.self, rawValue: context.rawArgs[0])
                } else if location.starts(with: "/") {
                    // / --> treat as local file system url
                    self = .customUrl(URL(filePath: location))
                } else {
                    // location is not a URL and not an absolute path --> treat it as a plist in the bundle
                    self = .custom(plistNameInBundle: location)
                }
            default:
                throw LaunchOptionDecodingError.unableToDecode(Self.self, rawValue: context.rawArgs[0])
            }
        }
    }
    
    
    static func firebaseOptions(for configSelector: FirebaseConfigSelector) throws(LoadingError) -> FirebaseOptions {
        if let overrideSelector = FeatureFlags.overrideFirebaseConfig {
            try _firebaseOptions(for: overrideSelector)
        } else {
            try _firebaseOptions(for: configSelector)
        }
    }
    
    
    private static func _firebaseOptions(for configSelector: FirebaseConfigSelector) throws(LoadingError) -> FirebaseOptions {
        logger.notice("[\(#function)] selector: \(String(describing: configSelector))")
        // swiftlint:disable legacy_objc_type
        // FirebaseOptions is an NSDictionary-based API...
        switch configSelector {
        case .region(let region):
            guard let bundlePlistUrl = Bundle.main.url(forResource: "GoogleService-Info", withExtension: "plist") else {
                // this should be practically unreachable...
                throw .unableToLoadFirebaseConfigPlist()
            }
            let combinedConfig: NSDictionary
            do {
                combinedConfig = try NSDictionary(contentsOf: bundlePlistUrl, error: ())
            } catch {
                throw .unableToLoadFirebaseConfigPlist(underlying: error)
            }
            let tmpUrl = URL.temporaryDirectory.appendingPathComponent("GoogleService-Info.tmp", conformingTo: .propertyList)
            defer {
                try? FileManager.default.removeItem(at: tmpUrl)
            }
            let key = try configKey(for: region)
            guard let configDict = combinedConfig[key] as? NSDictionary else {
                throw .unableToLoadFirebaseConfigPlist()
            }
            do {
                try configDict.write(to: tmpUrl)
            } catch {
                throw .unableToLoadFirebaseConfigPlist(underlying: error)
            }
            logger.notice("[\(#function)] using '\(key)' Firebase config")
            return try firebaseOptions(contentsOfFile: tmpUrl.path)
        case .custom(let plistNameInBundle):
            guard let bundlePlistUrl = Bundle.main.url(forResource: plistNameInBundle, withExtension: "plist") else {
                throw .plistNotFoundInBundle(name: plistNameInBundle)
            }
            logger.notice("[\(#function)] returning config for '\(plistNameInBundle).plist' in bundle")
            return try firebaseOptions(contentsOfFile: bundlePlistUrl.path)
        case .customUrl(let url):
            guard url.isFileURL else {
                preconditionFailure("Only file urls are supported when loading external firebase configs!")
            }
            logger.notice("[\(#function)] returning config for plist at '\(url.path)'")
            return try firebaseOptions(contentsOfFile: url.path)
        }
        // swiftlint:enable legacy_objc_type
    }


    private static func firebaseOptions(contentsOfFile path: String) throws(LoadingError) -> FirebaseOptions {
        guard let options = FirebaseOptions(contentsOfFile: path) else {
            throw .invalidFirebaseConfigPlist(path: path)
        }
        return options
    }

    /// The key of a region's config in the combined `GoogleService-Info.plist`.
    private static func configKey(for region: Locale.Region) throws(LoadingError) -> String {
        switch region {
        case .unitedStates:
            return "US"
        case .unitedKingdom:
            return "UK"
        default:
            throw .unsupportedRegion(region)
        }
    }

    /// The bucket for collected health data, from the `DATA_COLLECTION_BUCKET` key of the selected Firebase config.
    ///
    /// `nil` if the config doesn't name one, in which case uploads go to the default bucket.
    static func dataCollectionBucket(for configSelector: FirebaseConfigSelector) -> String? {
        // swiftlint:disable legacy_objc_type
        let config: NSDictionary?
        switch configSelector {
        case .region(let region):
            let combinedConfig = Bundle.main.url(forResource: "GoogleService-Info", withExtension: "plist")
                .flatMap { try? NSDictionary(contentsOf: $0, error: ()) }
            config = (try? configKey(for: region)).flatMap { combinedConfig?[$0] as? NSDictionary }
        case .custom(let plistNameInBundle):
            config = Bundle.main.url(forResource: plistNameInBundle, withExtension: "plist")
                .flatMap { try? NSDictionary(contentsOf: $0, error: ()) }
        case .customUrl(let url):
            config = try? NSDictionary(contentsOf: url, error: ())
        }
        // swiftlint:enable legacy_objc_type
        guard let bucket = config?["DATA_COLLECTION_BUCKET"] as? String, !bucket.isEmpty else {
            return nil
        }
        return bucket
    }

    
    @MainActor
    static func initialAppLaunchConfig() throws(LoadingError) -> [any Module] {
        let studyVariant = LocalPreferencesStore.standard[.enrolledStudyVariant] ?? .stanford
        return if FeatureFlags.disableFirebase {
            baseModules(preferredLocale: .autoupdatingCurrent)
        } else if let selector = FeatureFlags.overrideFirebaseConfig {
            try config(for: selector, studyVariant: studyVariant)
        } else if let selector = LocalPreferencesStore.standard[.enrolledFirebaseConfig],
                  LocalPreferencesStore.standard[.onboardingFlowComplete] || !StudyManager().studyEnrollments.isEmpty {
            // Completed onboarding takes the original restoration path without inspecting the study store.
            // Otherwise, only restore an actual (possibly unfinished) enrollment, not an abandoned region selection.
            // Leave the saved value untouched, including when it isn't restored.
            try config(for: selector, studyVariant: studyVariant)
        } else {
            []
        }
    }
    
    /// The set of modules which we always want to load, regardless of whether Firebase is enabled or disabled.
    @MainActor
    @ArrayBuilder<any Module>
    static func baseModules(preferredLocale: Locale) -> [any Module] {
        StudyManager(preferredLocale: preferredLocale)
        ConsentManager()
    }
    
    /// Constructs an Array of Grove Modules for loading Firebase and the other related modules, configured based on the specified selector.
    ///
    /// Throws if there was an issue resolving the selector.
    @MainActor
    static func config( // swiftlint:disable:this function_body_length
        for configSelector: FirebaseConfigSelector,
        studyVariant: StudyVariant = .stanford
    ) throws(LoadingError) -> [any Module] {
        let configSelector = FeatureFlags.overrideFirebaseConfig ?? configSelector
        // An existing enrollment wins, even over a forced variant. See `checkingStudyVariantConsistency()` for how we surface that disagreement.
        let studyVariant = LocalPreferencesStore.standard[.enrolledStudyVariant] ?? FeatureFlags.forcedStudyVariant ?? studyVariant
        let configuration = StudyConfiguration(firebaseConfig: configSelector, studyVariant: studyVariant)
        let preferredLocale = studyVariant.preferredLocale
        guard !FeatureFlags.disableFirebase else {
            activeConfiguration = configuration
            return baseModules(preferredLocale: preferredLocale)
        }
        let firebaseOptions = try firebaseOptions(for: configSelector)
        logger.notice("Created FirebaseOptions for project '\(firebaseOptions.projectID ?? "")'")
        let dataCollectionBucket = dataCollectionBucket(for: configSelector)
        activeConfiguration = configuration
        return Array { // swiftlint:disable:this closure_body_length
            ConfigureFirebaseApp(/*name: "My Heart Counts", */options: firebaseOptions)
            firestore
            FirestoreCacheCleanup()
            AccountConfiguration(
                service: FirebaseAccountService(providers: [.emailAndPassword], emulatorSettings: accountEmulator),
                storageProvider: FirestoreAccountStorage(storeIn: FirebaseConfiguration.usersCollection),
                configuration: [
                    .requires(\.userId),
                    .requires(\.name),
                    // additional values stored using the `FirestoreAccountStorage` within our Standard implementation
                    .manual(\.dateOfBirth),
                    // account mgmt
                    .manual(\.studyVariant),
                    .manual(\.didOptInToTrial),
                    .manual(\.futureStudies),
                    .manual(\.hasWithdrawnFromStudy),
                    .manual(\.dateOfEnrollment),
                    .manual(\.historicalHealthUploadCompletedDate),
                    // consent tracking
                    .manual(\.lastSignedConsentDate),
                    .manual(\.lastSignedConsentVersion),
                    // notifications
                    .manual(\.fcmToken),
                    .manual(\.preferredWorkoutTypes),
                    .manual(\.preferredNudgeNotificationTime),
                    .manual(\.stageOfChange),
                    .manual(\.postTrialNudgesOptIn),
                    // demographics
                    .manual(\.mhcGenderIdentity),
                    .manual(\.usRegion),
                    .manual(\.usZipCodePrefix),
                    .manual(\.householdIncomeUS),
                    .manual(\.ukRegion),
                    .manual(\.ukPostcode),
                    .manual(\.householdIncomeUK),
                    .manual(\.heightInCM),
                    .manual(\.weightInKG),
                    .manual(\.raceEthnicity),
                    .manual(\.ethnicityUK),
                    .manual(\.latinoStatus),
                    .manual(\.biologicalSexAtBirth),
                    .manual(\.bloodType),
                    .manual(\.educationUS),
                    .manual(\.educationUK),
                    .manual(\.comorbidities),
                    .manual(\.nhsNumber),
                    .manual(\.chiNumber),
                    .manual(\.referralSource),
                    // env tracking
                    .manual(\.mostRecentOnboardingStep),
                    .manual(\.lastActiveDate),
                    .manual(\.timeZone),
                    .manual(\.language),
                    .manual(\.preferredMeasurementSystem),
                    // internal stuff
                    .manual(\.enableDebugMode)
                ]
            )
            if FeatureFlags.useFirebaseEmulator {
                FirebaseStorageConfiguration(emulatorSettings: (host: "localhost", port: 9199))
                FirebaseFunctions(emulatorHost: "localhost", port: 5001)
            } else {
                FirebaseStorageConfiguration()
                FirebaseFunctions()
            }
            if let dataCollectionBucket {
                DataCollectionStorage(
                    bucket: dataCollectionBucket,
                    emulatorConfig: FeatureFlags.useFirebaseEmulator ? (host: "localhost", port: 9199) : nil
                )
            }
            baseModules(preferredLocale: preferredLocale)
            HealthKitStatsCalculator()
            StatsStore()
            EnvironmentTracking()
            LoadFirebaseTracking() // intentionally the very last thing!!!
        }
    }
    
    private static var accountEmulator: (host: String, port: Int)? {
        if FeatureFlags.useFirebaseEmulator {
            (host: "localhost", port: 9099)
        } else {
            nil
        }
    }
    
    
    private static var firestore: Firestore {
        let settings = FirestoreSettings()
        // make firebase callbacks run off the main queue.
        // this exists primarily to allow `FirestoreCacheCleanup` to block the main thread until its cleanup operations have completed
        settings.dispatchQueue = DispatchQueue(label: "edu.stanford.MyHeartCounts.firestore")
        if FeatureFlags.useFirebaseEmulator {
            settings.host = "localhost:8080"
            settings.cacheSettings = MemoryCacheSettings()
            settings.isSSLEnabled = false
        } else {
            // We explicitly limit the size of the local cache.
            // This is in fact the same limit as is already the default,
            // but the hope here is that specifying it explicitly causes
            // Firebase to be more strict.
            settings.cacheSettings = PersistentCacheSettings(
                sizeBytes: NSNumber(value: 100 * 1024 * 1024) // swiftlint:disable:this legacy_objc_type
            )
        }
        return Firestore(
            settings: settings
        )
    }
}


extension DeferredConfigLoading {
    enum CurrentStudyVariant: Hashable, Sendable {
        case active(StudyVariant)
        case pending(StudyVariant)
        case unknown
        
        func effective() -> StudyVariant? {
            switch self {
            case .active(let variant), .pending(let variant):
                variant
            case .unknown:
                nil
            }
        }
        
        func effective(fallback: @autoclosure () -> StudyVariant) -> StudyVariant {
            effective() ?? fallback()
        }
    }
    
    
    enum StudyVariantError: Error, Equatable {
        case missingConfiguration
        case mismatch(expected: StudyVariant, actual: StudyVariant)
    }
    
    
    /// Resolves the variant before enrollment; an existing enrollment cannot change variants.
    @MainActor
    static func setCurrentStudyVariant(_ newVariant: StudyVariant) throws {
        guard let activeConfiguration else {
            throw StudyVariantError.missingConfiguration
        }
        if let override = FeatureFlags.forcedStudyVariant, override != newVariant {
            // caller is trying to set the study variant to something that isn't the forced override
            throw StudyVariantError.mismatch(expected: override, actual: newVariant)
        }
        let previousVariant = activeConfiguration.studyVariant
        try activeConfiguration.selectStudyVariant(
            newVariant,
            enrolledVariant: LocalPreferencesStore.standard[.enrolledStudyVariant]
        )
        guard previousVariant != newVariant else {
            return
        }
        if let grove = GroveAppDelegate.grove {
            grove.module(StudyManager.self)?.preferredLocale = newVariant.preferredLocale
            grove.module(NewsManager.self)?.invalidate()
        }
    }

    /// Saves both selections before enrollment can persist study data.
    @MainActor
    static func persistActiveConfiguration() throws {
        guard let activeConfiguration else {
            throw StudyVariantError.missingConfiguration
        }
        try activeConfiguration.persist(in: .standard)
    }

    /// Clears the saved selection after the local enrollment has been removed.
    @MainActor
    static func clearEnrolledConfiguration() {
        let prefs = LocalPreferencesStore.standard
        prefs[.enrolledFirebaseConfig] = nil
        prefs[.enrolledStudyVariant] = nil
    }
}


extension Grove {
    fileprivate enum LoadState {
        case loaded
        case notLoaded(waiters: [CheckedContinuation<Void, Never>])
    }
    
    fileprivate static let loadState = Mutex<LoadState>(.notLoaded(waiters: []))
    
    static var didLoadFirebase: Bool {
        loadState.withLock {
            switch $0 {
            case .loaded: true
            case .notLoaded: false
            }
        }
    }
    
    @MainActor // IDEA maybe rename this? (here and elsewhere (it's not just firebase any more))
    static func loadFirebase(for region: Locale.Region, studyVariant: StudyVariant = .stanford) {
        guard let grove = GroveAppDelegate.grove else {
            fatalError("Grove not loaded")
        }
        guard !didLoadFirebase else {
            DeferredConfigLoading.logger.error("Did already load firebase, now asked to do it again, for a potentially different config. Will skip.")
            return
        }
        grove.loadFirebase(for: region, studyVariant: studyVariant)
    }
    
    @MainActor
    private func loadFirebase(for region: Locale.Region, studyVariant: StudyVariant) {
        DeferredConfigLoading.logger.notice("Will load firebase")
        let config: [any Module]
        do throws(DeferredConfigLoading.LoadingError) {
            config = try DeferredConfigLoading.config(for: .region(region), studyVariant: studyVariant)
        } catch {
            DeferredConfigLoading.logger.error("Unable to load firebase: \(error)")
            return
        }
        for module in config {
            self.loadModule(module)
        }
        DeferredConfigLoading.logger.notice("Did load firebase")
    }
    
    
    // periphery:ignore - unused but important
    /// Waits until firebase has been loaded.
    ///
    /// Suspends the caller until firebase has been loaded and configured.
    /// If firebase is already loaded, the function returns immediately.
    /// If firebase doesn't end up getting loaded, the function will never return.
    static func waitForFirebaseLoaded() async {
        guard !didLoadFirebase else {
            // already loaded
            return
        }
        await withCheckedContinuation { continuation in
            let didLoad = Self.loadState.withLock { state in
                switch state {
                case .loaded:
                    // firebase loaded in the time between the start of the function here
                    // and the `withCheckedContinuation` body being executed
                    return true
                case .notLoaded(let waiters):
                    state = .notLoaded(waiters: waiters + [continuation])
                    return false
                }
            }
            if didLoad {
                continuation.resume()
            }
        }
    }
}


extension FirebaseOptions {
    // periphery:ignore - unused but important
    convenience init?(plistInBundle filename: String) {
        guard let path = Bundle.main.path(forResource: filename, ofType: "plist") else {
            preconditionFailure("Unable to find '\(filename).plist' in bundle")
        }
        self.init(contentsOfFile: path)
    }
}


private final class LoadFirebaseTracking: Module {
    @Dependency(StudyBundleLoader.self)
    private var studyLoader
    
    func configure() {
        let waiters: [CheckedContinuation<Void, Never>] = Grove.loadState.withLock { state in
            switch exchange(&state, with: .loaded) {
            case .loaded: []
            case .notLoaded(let waiters): waiters
            }
        }
        for waiter in waiters {
            waiter.resume()
        }
        Task {
            try? await studyLoader.update()
        }
    }
}
