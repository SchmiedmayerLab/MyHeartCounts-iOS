//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2023 Stanford University
//
// SPDX-License-Identifier: MIT
//

import SpeziFoundation

extension LocalPreferenceKeys {
    /// A `Bool` flag indicating of the onboarding was completed.
    static let onboardingFlowComplete = LocalPreferenceKey<Bool>("onboardingFlowComplete", default: false)
    
    /// Triggers a `Firestore.clearPersistence()` call the next time firebase is loaded (i.e., during the next launch).
    static let shouldClearFirestoreCacheOnNextLaunch = LocalPreferenceKey<Bool>(
        "shouldClearFirestoreCacheOnNextLaunch",
        default: true
    )
}
