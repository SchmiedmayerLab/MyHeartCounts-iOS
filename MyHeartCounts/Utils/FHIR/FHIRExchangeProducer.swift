//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFHIRContract
import GroveQuestionnaireFHIR
import GroveSensorKitFHIR


extension FHIRExchangeStateStore {
    /// The producer every exporter of `subject` converts through: MHC's identity scope under `secret`, and `facts` as
    /// every record states them.
    ///
    /// Every exporter factory reads the identity secret once and passes it here and to its repository scope. A producer
    /// states `facts` for as long as it lives, so each exporter is built as often as its facts can change: HealthKit's when
    /// the account or enrollment changes, SensorKit's per batch, and the questionnaire exporter per response.
    func exchangeProducer(
        subject: FHIRExchangeSubject,
        facts: ConversionFacts,
        secret: FHIRExchangeIdentitySecret
    ) throws -> ExchangeProducer {
        try ExchangeProducer(
            identityScope: try Self.identityScope(of: secret, subject: subject),
            subject: .logical(subject.identity),
            application: try facts.application,
            host: try facts.host,
            studies: try facts.studies(for: subject)
        )
    }
}


extension FHIRExchangeStateStore {
    /// The exporter of one SensorKit batch of `subject`, stating `facts`: those the batch was first published under.
    ///
    /// Building it reads the keychain identity secret once.
    func sensorKitExporter(subject: FHIRExchangeSubject, facts: ConversionFacts) throws -> SensorKitFHIRExporter {
        let secret = try identitySecret()
        let repositoryScope = try Self.repositoryScope(.sensorKit, subject: subject, secret: secret)
        return try SensorKitFHIRExporter(
            producer: try exchangeProducer(subject: subject, facts: facts, secret: secret),
            repositoryScope: repositoryScope,
            visitLocationIdentifierSystem: FHIRExchangeIdentifiers.visitLocation,
            options: .myHeartCounts(
                nativeRecordSystem: try FHIRExchangeIdentifiers.sensorKitSourceRecord(
                    scope: Self.sensorKitRecordScope(of: repositoryScope, secret: secret)
                )
            )
        )
    }
}


extension FHIRExchangeStateStore {
    /// The exporter of `subject`'s questionnaire responses, under the facts as they stand now.
    ///
    /// Building it reads the keychain identity secret once, and the app facts and enrollment.
    func questionnaireExporter(subject: FHIRExchangeSubject) async throws -> QuestionnaireFHIRExporter {
        let secret = try identitySecret()
        return QuestionnaireFHIRExporter(
            producer: try exchangeProducer(subject: subject, facts: try await .current(), secret: secret),
            repositoryScope: try Self.repositoryScope(.questionnaire, subject: subject, secret: secret)
        )
    }
}


extension SensorKitFHIRExporter.Options {
    /// Discloses each record's SensorKit source-record identifier under `nativeRecordSystem` on the record's primary output.
    ///
    /// The identifier hashes only the sensor, the product type and the record's coordinates, so two participants with the
    /// same watch state equal values: the system must be the repository's own, as
    /// ``FHIRExchangeIdentifiers/sensorKitSourceRecord(scope:)`` scopes it.
    static func myHeartCounts(nativeRecordSystem: IdentifierSystem) -> Self {
        var options = Self()
        options.nativeIdentifier = .authorized(system: nativeRecordSystem)
        return options
    }
}
