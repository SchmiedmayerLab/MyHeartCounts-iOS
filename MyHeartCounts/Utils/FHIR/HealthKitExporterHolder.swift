//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import Grove
import GroveFoundation
import GroveHealthKitFHIR
import GroveKeychainStorage
import OSLog
import Synchronization


/// The app's one HealthKit exporter and the subject it converts for, fenced to the account generation they were built
/// under; `MyHeartCountsStandard` rebuilds them when the account or its enrollment changes.
///
/// Staging stores the subject with every row it inserts.
final class HealthKitExporterHolder: Module, DefaultInitializable, Sendable {
    /// The exporter of the signed-in account, and that account as the subject of what the exporter converts.
    struct Current: Sendable {
        let exporter: HealthKitFHIRExporter
        let subject: FHIRExchangeSubject
    }

    private struct State {
        let accountDataGeneration: Int
        let current: Current
    }

    private let state = Mutex<State?>(nil)

    nonisolated init() {}

    func configure() {
        Task(priority: .utility) {
            Self.removeRetiredLedger()
        }
    }

    /// The exporter and subject of a batch captured under `accountDataGeneration`: a lock and a comparison.
    ///
    /// Throws ``FHIRExchangeStateError/healthKitExporterUnavailable`` while no account's exporter is built, and
    /// ``FHIRExchangeStateError/staleAccountGeneration(captured:current:)`` for a batch of another account
    /// generation, so a batch captured before a logout never exports under the next account.
    func current(forBatchOf accountDataGeneration: Int) throws -> Current {
        try state.withLock { state in
            guard let state else {
                throw FHIRExchangeStateError.healthKitExporterUnavailable
            }
            guard state.accountDataGeneration == accountDataGeneration else {
                throw FHIRExchangeStateError.staleAccountGeneration(captured: accountDataGeneration, current: state.accountDataGeneration)
            }
            return state.current
        }
    }

    /// The exporter of a batch captured under `accountDataGeneration`; see ``current(forBatchOf:)``.
    func healthKitExporter(forBatchOf accountDataGeneration: Int) throws -> HealthKitFHIRExporter {
        try current(forBatchOf: accountDataGeneration).exporter
    }

    /// Replaces the exporter and its subject; `nil` clears them while no account is signed in.
    func set(_ current: Current?, accountDataGeneration: Int) {
        state.withLock { state in
            state = current.map { State(accountDataGeneration: accountDataGeneration, current: $0) }
        }
    }
}


// MARK: Retired Ledger Cleanup

extension HealthKitExporterHolder {
    /// Removes what the exchange-event ledger of earlier builds left behind: its directory, the lock file beside it,
    /// and its keychain item.
    ///
    /// A failure is logged and retried on the next launch; the preference is set only once every step succeeded.
    private static func removeRetiredLedger() {
        let preferences = LocalPreferencesStore.standard
        guard !preferences[.didRemoveRetiredExchangeLedger] else {
            return
        }
        let support = URL.applicationSupportDirectory
        let leftovers = [
            support.appending(path: "FHIRExchangeLedger", directoryHint: .isDirectory),
            support.appending(path: "FHIRExchangeLedger.lock", directoryHint: .notDirectory)
        ]
        do {
            for url in leftovers where FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                try FileManager.default.removeItem(at: url)
            }
            try KeychainStorage().deleteCredentials(
                for: .genericPassword(
                    forService: "edu.stanford.MyHeartCounts.fhirExchangeLedger",
                    storage: .keychain(requireUserPresence: false, accessGroup: nil)
                )
            )
            preferences[.didRemoveRetiredExchangeLedger] = true
        } catch {
            logger.error("Unable to remove the retired FHIR exchange ledger: \(error)")
        }
    }
}


extension LocalPreferenceKeys {
    /// Whether the files and the keychain item of the retired exchange-event ledger are gone.
    fileprivate static let didRemoveRetiredExchangeLedger = LocalPreferenceKey<Bool>("didRemoveRetiredExchangeLedger", default: false)
}
