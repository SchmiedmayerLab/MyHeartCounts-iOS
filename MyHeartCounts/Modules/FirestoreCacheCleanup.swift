//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Dispatch
import FirebaseFirestore
import OSLog
import Spezi
import SpeziFoundation
import Synchronization


/// Performs a one-time `clearPersistence()` call on the firestore.
///
/// - Important: This module must be configured as early as possible after Firebase is loaded.
final class FirestoreCacheCleanup: Module, EnvironmentAccessible, @unchecked Sendable {
    @Application(\.logger)
    private var logger
    
    func configure() {
        let prefs = LocalPreferencesStore.standard
        guard prefs[.shouldClearFirestoreCacheOnNextLaunch] else {
            return
        }
        // Since firebase requires that `clearPersistence()` be called before any other firestore operations,
        // we need to explicitly block the main thread until this operation has completed.
        let semaphore = DispatchSemaphore(value: 0)
        let error = Mutex<(any Error)?>(nil)
        Firestore.firestore().clearPersistence { err in
            error.withLock { $0 = err }
            semaphore.signal()
        }
        semaphore.wait()
        if let error = error.withLock({ $0 }) {
            logger.error("Error clearing firestore local persistence: \(error)")
            // We intentionally keep the flag set to `true`, so that we can retry on the next launch.
        } else {
            logger.notice("Successfully cleared the firestore local cache")
            prefs[.shouldClearFirestoreCacheOnNextLaunch] = false
        }
    }
}
