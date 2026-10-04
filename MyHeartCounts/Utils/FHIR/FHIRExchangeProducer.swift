//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFHIRContract
import GroveSensorKitFHIR


extension FHIRExchangeStateStore {
    /// The producer every exporter of `subject` reserves its exchange events through: MHC's identity scope under
    /// `secret`, `facts` as each new event freezes them, and `ledger` fenced to this store's account generation.
    ///
    /// Every exporter factory reads the identity secret once and passes it here and to its repository scope. Building
    /// the producer opens no ledger; build one per batch, so new events state the facts as they stand.
    func exchangeProducer(
        subject: FHIRExchangeSubject,
        ledger: FHIRExchangeLedger,
        facts: FHIRExchangeEventFacts,
        secret: FHIRExchangeIdentitySecret
    ) throws -> ExchangeProducer {
        try ExchangeProducer(
            identityScope: try Self.identityScope(of: secret),
            subject: .logical(subject.identity),
            application: try facts.application,
            host: try facts.host,
            studies: try facts.studies(for: subject),
            storage: ledger.storage(accountDataGeneration: accountDataGeneration)
        )
    }
}


extension FHIRExchangeStateStore {
    /// The exporter of one SensorKit batch of `subject`, reserving new events under the facts as they stand now.
    ///
    /// Building it reads the keychain identity secret once, and the app facts and enrollment; it opens no ledger.
    func sensorKitExporter(subject: FHIRExchangeSubject, ledger: FHIRExchangeLedger) throws -> SensorKitFHIRExporter {
        try sensorKitExporter(subject: subject, ledger: ledger, facts: .current())
    }

    /// ``sensorKitExporter(subject:ledger:)`` reserving new events under `facts` instead of the current ones.
    func sensorKitExporter(
        subject: FHIRExchangeSubject,
        ledger: FHIRExchangeLedger,
        facts: FHIRExchangeEventFacts
    ) throws -> SensorKitFHIRExporter {
        let secret = try identitySecret()
        return try SensorKitFHIRExporter(
            producer: try exchangeProducer(subject: subject, ledger: ledger, facts: facts, secret: secret),
            repositoryScope: try Self.repositoryScope(.sensorKit, subject: subject, secret: secret),
            visitLocationIdentifierSystem: FHIRExchangeIdentifiers.visitLocation,
            options: .myHeartCounts
        )
    }
}


extension SensorKitFHIRExporter.Options {
    /// Discloses each record's SensorKit source-record identifier under MHC's own system on the record's primary output.
    static let myHeartCounts: Self = {
        var options = Self()
        options.nativeIdentifier = .authorized(system: FHIRExchangeIdentifiers.sensorKitSourceRecord)
        return options
    }()
}
