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

    /// Captures the account an exchange is composed for, refusing one that already rotated.
    static func capture(accountID: String, accountDataGeneration: Int) throws -> Self {
        try validateWrites(for: accountDataGeneration)
        return Self(accountDataGeneration: accountDataGeneration, accountID: accountID)
    }

    /// The account fence: a rotated generation or a pending cleanup refuses every write.
    static func validateWrites(
        for accountDataGeneration: Int,
        currentGeneration: Int = LocalPreferencesStore.standard[.accountDataGeneration],
        cleanupPending: Bool = LocalPreferencesStore.standard[.pendingAccountDataCleanupRequired]
    ) throws {
        guard accountDataGeneration == currentGeneration, !cleanupPending else {
            throw FHIRExchangeDestinationError.accountChanged
        }
    }

    func validateCurrentAccount() throws {
        try Self.validateWrites(for: accountDataGeneration)
    }
}
