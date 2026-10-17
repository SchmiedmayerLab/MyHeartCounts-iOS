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
    /// Only HealthKit samples need one. Building it reads the keychain identity secret once, and the app facts
    /// and enrollment; it opens no ledger. Each export call through it then costs one ledger transaction for its
    /// reservations, and its receipt at most one more.
    func healthKitExporter(subject: FHIRExchangeSubject, ledger: FHIRExchangeLedger) throws -> HealthKitFHIRExporter {
        try healthKitExporter(subject: subject, ledger: ledger, facts: .current())
    }

    /// ``healthKitExporter(subject:ledger:)`` reserving new events under `facts` instead of the current ones.
    func healthKitExporter(
        subject: FHIRExchangeSubject,
        ledger: FHIRExchangeLedger,
        facts: FHIRExchangeEventFacts
    ) throws -> HealthKitFHIRExporter {
        let secret = try identitySecret()
        return try HealthKitFHIRExporter(
            producer: try exchangeProducer(subject: subject, ledger: ledger, facts: facts, secret: secret),
            repositoryScope: try Self.repositoryScope(.healthKit, subject: subject, secret: secret),
            options: .myHeartCounts
        )
    }
}


extension HealthKitFHIRExporter.Options {
    /// Discloses the HealthKit UUID under MHC's own system on every output and retraction target, keeps it
    /// as `Bundle.id` until the backend keys documents on the identifiers inside the Bundle, states MHC as the
    /// writer of the samples MHC wrote, and as their gateway only when this very build wrote them (the same
    /// bundle identifier, and `HKSourceRevision.version` equal to this build).
    static let myHeartCounts: Self = {
        var options = Self()
        options.nativeIdentifier = .authorized(system: FHIRExchangeIdentifiers.healthKitNativeRecord)
        options.legacyBundleID = .healthKitUUID
        options.role = .gatewayForOwnWrites
        options.writer = .applications(Set([Bundle.main.bundleIdentifier].compactMap(\.self)))
        options.measuresThroughput = FeatureFlags.measureExporterThroughput || FeatureFlags.recordHealthKitExportLog
        return options
    }()
}
