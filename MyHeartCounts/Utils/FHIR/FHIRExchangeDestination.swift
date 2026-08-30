//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import GroveFoundation


enum FHIRExchangeDestinationError: Error, Equatable {
    case accountChanged
}


/// One account-scoped Firebase destination captured before an exchange is composed.
struct FHIRExchangeDestination: Equatable, Sendable {
    let accountDataGeneration: Int
    let accountID: String

    func validateCurrentAccount() throws {
        let preferences = LocalPreferencesStore.standard
        try validate(
            currentGeneration: preferences[.accountDataGeneration],
            cleanupPending: preferences[.pendingAccountDataCleanupRequired]
        )
    }

    func validate(currentGeneration: Int, cleanupPending: Bool) throws {
        guard currentGeneration == accountDataGeneration, !cleanupPending else {
            throw FHIRExchangeDestinationError.accountChanged
        }
    }
}
