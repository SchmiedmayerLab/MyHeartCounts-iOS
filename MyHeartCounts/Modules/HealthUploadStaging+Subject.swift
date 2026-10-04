//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import GroveFoundation


#if DEBUG
extension HealthUploadStaging {
    /// Stages against a fixed subject and isolated ledgers, standing in for the signed-in account
    /// a test has no way to supply. Compiled out of release builds, so a shipping app always
    /// attributes to the account and reserves in the app's ledgers.
    nonisolated static func forTesting(
        persistence: Persistence,
        autoElideUploadsWhenInsertingDeletions: Bool = true,
        subject: FHIRExchangeSubject
    ) -> HealthUploadStaging {
        let staging = Self(
            persistence: persistence,
            autoElideUploadsWhenInsertingDeletions: autoElideUploadsWhenInsertingDeletions
        )
        staging.testingSubject = subject
        staging.testingStateStore = FHIRExchangeStateStore(
            accountDataGeneration: LocalPreferencesStore.standard[.accountDataGeneration]
        )
        // Fenced to the live preferences, as staging itself is.
        staging.testingLedger = FHIRExchangeLedger(location: .inMemory)
        return staging
    }
}
#endif
