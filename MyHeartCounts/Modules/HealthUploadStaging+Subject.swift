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
    /// What a test stages against instead of the signed-in account and the app's exchange state.
    struct TestingOverrides {
        /// The subject staged samples are attributed to.
        var subject: FHIRExchangeSubject
        /// An isolated identity store, so staging in a test never touches the host's encrypted exchange state.
        var stateStore: FHIRExchangeStateStore
        /// An isolated ledger, so staging in a test never reserves in the host's exchange-event ledger.
        var ledger: FHIRExchangeLedger
        /// The app facts new events are reserved under, so a test can change them between deliveries; `nil` uses the app's.
        var facts: FHIRExchangeEventFacts?
    }

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
        staging.testing = TestingOverrides(
            subject: subject,
            // Fenced to the live preferences, as staging itself is.
            stateStore: FHIRExchangeStateStore(accountDataGeneration: LocalPreferencesStore.standard[.accountDataGeneration]),
            ledger: FHIRExchangeLedger(location: .inMemory)
        )
        return staging
    }
}
#endif
