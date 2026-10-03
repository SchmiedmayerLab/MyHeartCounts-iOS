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
    /// The exporter of one batch: the signed-in participant, this installation's facts as they
    /// stand now, MHC's identity scope, and this store as the sequencer's ledger.
    ///
    /// Building one reads the keychain secret and the enrollment once; converting a batch through
    /// it then costs one ledger transaction for the reservations and none per sample.
    func healthKitExporter(subject: FHIRExchangeSubject) throws -> HealthKitFHIRExporter {
        let facts = try FHIRExchangeEventFacts.current()
        let producer = try ExchangeProducer(
            identityScope: try identityScope(),
            subject: .logical(subject.identity),
            application: try facts.application,
            host: try facts.host,
            studies: try facts.studies(for: subject),
            // A reservation lives until its source cursor is acknowledged, however late that is.
            sequencer: ExchangeEventSequencer(storage: self, retention: .init(maximumAge: .infinity))
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
