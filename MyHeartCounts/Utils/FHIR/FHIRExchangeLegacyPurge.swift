//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFoundation
import OSLog


extension LocalPreferenceKeys {
    /// Whether the encrypted state no longer holds HealthKit reservations from before `FHIRExchangeLedger`.
    static let didPurgeLegacyHealthKitExchangeEvents = LocalPreferenceKey<Bool>(
        "didPurgeLegacyHealthKitExchangeEvents",
        default: false
    )
}


extension FHIRExchangeStateStore {
    /// Runs ``purgeLegacyHealthKitEvents()`` until it succeeds once.
    ///
    /// Nothing is imported into `FHIRExchangeLedger`: an older converter built those reservations, so no
    /// redelivery could reuse them. A failure, such as the encrypted state being unreadable before the first
    /// unlock, is logged and retried at the next launch; the ledger never waits for it.
    static func purgeLegacyHealthKitEventsOnce(
        in store: FHIRExchangeStateStore,
        preferences: LocalPreferencesStore = .standard
    ) {
        guard !preferences[.didPurgeLegacyHealthKitExchangeEvents] else {
            return
        }
        do {
            try store.purgeLegacyHealthKitEvents()
            preferences[.didPurgeLegacyHealthKitExchangeEvents] = true
        } catch {
            logger.error("Unable to purge the legacy HealthKit exchange events; retrying at the next launch: \(error)")
        }
    }
}
