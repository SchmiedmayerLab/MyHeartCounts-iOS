//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Observation
import SpeziAccount


extension Account {
    /// Whether the account details are present and fully loaded (not `isIncomplete`).
    @MainActor private var detailsAreReady: Bool {
        guard let details else {
            return false
        }
        return !details.isIncomplete
    }
    
    /// Waits until the account details have been fully loaded.
    ///
    /// "Fully loaded" means ``details`` is non-`nil` and no longer flagged ``AccountDetails/isIncomplete`` —
    /// i.e. the externally-stored values (e.g. those persisted via `FirestoreAccountStorage`) have been fetched,
    /// not just the synchronously-available identity keys present when `.associatedAccount` first fires.
    ///
    /// The purpose of this function is to have a client-side fix/workaround for https://github.com/SchmiedmayerLab/MyHeartCounts-iOS/issues/169
    /// i.e., the issue where writes to the account details very early into the launch of the app, before they have been fully loaded by SpeziFirebase,
    /// will somehow race with SpeziFirebase's account details loading and will leave `account.details` in an incomplete state (despite `AccountDetails.isIncomplete` being `false`).
    /// If the first account details update waits until the details have been fully loaded, everything will work correctly.
    ///
    /// - Note: This function will only work correctly if **nothing** in the app has written account details before the initial load has completed.
    @MainActor
    func waitForAccountDetailsReady() async {
        while !detailsAreReady {
            if Task.isCancelled {
                return
            }
            // The condition check above and the observation registration below run contiguously on the main actor
            // (no `await` between them), so `details` cannot change in the gap and no update can be missed.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                withObservationTracking {
                    _ = detailsAreReady
                } onChange: {
                    continuation.resume()
                }
            }
        }
    }
}
