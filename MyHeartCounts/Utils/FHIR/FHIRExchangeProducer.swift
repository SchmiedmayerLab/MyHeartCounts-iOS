//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFHIRContract


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
