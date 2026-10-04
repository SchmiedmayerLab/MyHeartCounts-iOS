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
    /// Whether the encrypted state no longer holds the exchange events older builds reserved in it.
    static let didPurgeLegacyExchangeEvents = LocalPreferenceKey<Bool>(
        "didPurgeLegacyExchangeEvents",
        default: false
    )
}


extension FHIRExchangeStateStore {
    /// Runs ``purgeLegacyExchangeEvents()`` until it succeeds once.
    ///
    /// The SensorKit retry digests the state holds are kept, so a batch pending at the upgrade still fails closed on
    /// drift; it redelivers under new events, and its Firestore documents, keyed by source record, are overwritten. A
    /// failure, such as the encrypted state being unreadable before the first unlock, is logged and retried at the next
    /// launch; the ledger never waits for it, and reading the state migrates it meanwhile.
    static func purgeLegacyExchangeEventsOnce(
        in store: FHIRExchangeStateStore,
        preferences: LocalPreferencesStore = .standard
    ) {
        guard !preferences[.didPurgeLegacyExchangeEvents] else {
            return
        }
        do {
            try store.purgeLegacyExchangeEvents()
            preferences[.didPurgeLegacyExchangeEvents] = true
        } catch {
            logger.error("Unable to purge the legacy exchange events; retrying at the next launch: \(error)")
        }
    }
}
