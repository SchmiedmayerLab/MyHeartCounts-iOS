//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import Spezi
import SpeziFoundation
import SpeziHealthKit
import SpeziStudy


@Observable
@MainActor
final class ClinicalRecordPermissions: Module, EnvironmentAccessible, Sendable {
    enum AuthorizationState: Hashable {
        /// The user already was prompted this, and made some decision to allow/deny.
        case decided
        /// The user was prompted but cancelled the authorization flow.
        case cancelled
        /// The user has not been prompted for clinical record access at all.
        case undetermined
    }
    
    /// Whether clinical records are available.
    static let isAvailable: Bool = !FeatureFlags.disableHealthRecords && HKHealthStore().supportsHealthRecords()
    
    // swiftlint:disable attributes
    @ObservationIgnored @Dependency(HealthKit.self) private var healthKit
    @ObservationIgnored @Dependency(StudyBundleLoader.self) private var studyLoader
    @ObservationIgnored @Dependency(StudyManager.self) private var studyManager: StudyManager?
    
    @ObservationIgnored @LocalPreference(.clinicalRecordAuthWasCancelledByUser)
    private var wasCancelledByUser
    // swiftlint:enable attributes
    
    private(set) var authorizationState: AuthorizationState = .undetermined
    
    func configure() {
        Task {
            _ = try? await studyLoader.update()
            await updateAuthorizationState()
        }
    }
    
    func updateAuthorizationState() async {
        /// HealthKit's opinion on whether we already asked for access.
        let healthKitValue = await healthKit.didAskForAuthorization(for: dataAccessRequirements())
        switch (healthKitValue, wasCancelledByUser) {
        case (true, _):
            authorizationState = .decided
            wasCancelledByUser = false // just to make sure this is correct.
        case (false, true):
            authorizationState = .cancelled
        case (false, false):
            authorizationState = .undetermined
        }
    }
    
    /// Prompts the user for authorization to access clinical record sample types, unless the user has cancelled a previous request.
    ///
    /// Also triggers any automatic health data collection for such sample types.
    func askForAuthorization(askAgainIfCancelledPreviously: Bool) async throws {
        guard Self.isAvailable else {
            return
        }
        await updateAuthorizationState()
        switch authorizationState {
        case .decided:
            return
        case .cancelled:
            guard askAgainIfCancelledPreviously else {
                return
            }
        case .undetermined:
            break
        }
        do {
            try await healthKit.askForAuthorization(for: dataAccessRequirements())
            await updateAuthorizationState()
            try await studyManager?.updateHealthDataCollection()
        } catch {
            if let error = error as? HKError, error.code == .errorUserCanceled {
                wasCancelledByUser = true
                await updateAuthorizationState()
            } else {
                throw error
            }
        }
    }
    
    func resetTracking() {
        wasCancelledByUser = false
    }
    
    private func dataAccessRequirements() async -> HealthKit.DataAccessRequirements {
        HealthKit.DataAccessRequirements(read: await requestedRecordTypes().lazy.map(\.hkSampleType))
    }
    
    private func requestedRecordTypes() async -> Set<SampleType<HKClinicalRecord>> {
        let imp = { (_ study: StudyDefinition) -> Set<SampleType<HKClinicalRecord>> in
            var types = Set<SampleType<HKClinicalRecord>>()
            for component in study.healthDataCollectionComponents {
                types.formUnion(component.sampleTypes.compactMap { $0 as? SampleType<HKClinicalRecord> })
                types.formUnion(component.optionalSampleTypes.compactMap { $0 as? SampleType<HKClinicalRecord> })
            }
            return types
        }
        if let enrollments = studyManager?.studyEnrollments, !enrollments.isEmpty {
            return enrollments.reduce(into: []) { types, enrollment in
                guard let studyDefinition = enrollment.studyBundle?.studyDefinition else {
                    return
                }
                types.formUnion(imp(studyDefinition))
            }
        } else if let studyDefinition = try? studyLoader.studyBundle?.get().studyDefinition {
            return imp(studyDefinition)
        } else {
            return []
        }
    }
}


extension LocalPreferenceKeys {
    fileprivate static let clinicalRecordAuthWasCancelledByUser = LocalPreferenceKey(
        "clinicalRecordAuthWasCancelledByUser",
        default: false
    )
}
