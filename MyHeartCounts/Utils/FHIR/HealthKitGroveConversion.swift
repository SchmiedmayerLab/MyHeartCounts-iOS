//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFHIRContract
import GroveHealthKitFHIR
import HealthKit


extension FHIRExchangeStateStore {
    /// The exporter of one batch: the signed-in participant, this installation's facts as they stand now,
    /// MHC's identity scope, and the ledger fenced to this store's account generation.
    ///
    /// Building one reads the keychain identity secret and the enrollment; it opens no ledger. Each export
    /// call through it then costs one ledger transaction for its reservations, and its receipt at most one more.
    func healthKitExporter(subject: FHIRExchangeSubject, ledger: FHIRExchangeLedger) throws -> HealthKitFHIRExporter {
        let facts = try FHIRExchangeEventFacts.current()
        let producer = try ExchangeProducer(
            identityScope: try identityScope(),
            subject: .logical(subject.identity),
            application: try facts.application,
            host: try facts.host,
            studies: try facts.studies(for: subject),
            sequencer: ledger.sequencer(accountDataGeneration: accountDataGeneration)
        )
        return try HealthKitFHIRExporter(
            producer: producer,
            repositoryScope: try repositoryScope(.healthKit, subject: subject),
            options: .myHeartCounts
        )
    }
}


extension HealthKitFHIRExporter.Options {
    /// Discloses the HealthKit UUID under MHC's own system on every output and retraction target,
    /// keeps it as `Bundle.id` until the backend keys documents on the identifiers inside the
    /// Bundle, and states MHC as the gateway of the samples it wrote itself.
    static let myHeartCounts: Self = {
        var options = Self()
        options.nativeIdentifier = .authorized(system: FHIRExchangeIdentifiers.healthKitNativeRecord)
        options.legacyBundleID = .healthKitUUID
        options.role = .gatewayForOwnWrites
        return options
    }()
}
