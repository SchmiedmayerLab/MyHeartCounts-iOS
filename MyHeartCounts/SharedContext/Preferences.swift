//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2023 Stanford University
//
// SPDX-License-Identifier: MIT
//

import GroveFoundation

extension LocalPreferenceKeys {
    /// A `Bool` flag indicating of the onboarding was completed.
    static let onboardingFlowComplete = LocalPreferenceKey<Bool>("onboardingFlowComplete", default: false)

    /// Blocks uploads until data belonging to the previous account has been cleared.
    static let pendingAccountDataCleanupRequired = LocalPreferenceKey<Bool>(
        "pendingAccountDataCleanupRequired",
        default: false
    )
    static let accountDataGeneration = LocalPreferenceKey<Int>("accountDataGeneration", default: 0)
    
    /// Triggers a `Firestore.clearPersistence()` call the next time firebase is loaded (i.e., during the next launch).
    static let shouldClearFirestoreCacheOnNextLaunch = LocalPreferenceKey<Bool>(
        "shouldClearFirestoreCacheOnNextLaunch",
        default: true
    )
}
