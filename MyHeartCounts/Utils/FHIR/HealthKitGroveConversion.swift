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
    /// The exporter of `subject`, the signed-in participant: this installation's facts as they stand when it is built, and
    /// MHC's identity scope.
    ///
    /// Only HealthKit samples need one, and the app keeps one per account and enrollment, which
    /// ``MyHeartCountsStandard/refreshHealthKitExporter()`` builds, never one per batch. Building it reads the keychain
    /// identity secret once, and the app facts and enrollment.
    func healthKitExporter(subject: FHIRExchangeSubject) async throws -> HealthKitFHIRExporter {
        try healthKitExporter(subject: subject, facts: try await .current())
    }

    /// ``healthKitExporter(subject:)`` stating `facts` instead of the current ones.
    func healthKitExporter(subject: FHIRExchangeSubject, facts: ConversionFacts) throws -> HealthKitFHIRExporter {
        let secret = try identitySecret()
        return try HealthKitFHIRExporter(
            producer: try exchangeProducer(subject: subject, facts: facts, secret: secret),
            repositoryScope: try Self.repositoryScope(.healthKit, subject: subject, secret: secret),
            options: .myHeartCounts
        )
    }
}


extension HealthKitFHIRExporter.Options {
    /// Discloses the HealthKit UUID under MHC's own system as the governed native identifier, on every primary output
    /// and retraction target, so that whoever ingests the uploads can dedupe a sample's copies by it. It reaches a receiver
    /// no other way, an export strips it, and it is never `Bundle.id`.
    ///
    /// States MHC as the writer of the samples MHC wrote, and as their gateway only when this very build wrote them (the
    /// same bundle identifier, and `HKSourceRevision.version` equal to this build).
    static let myHeartCounts: Self = {
        var options = Self()
        options.nativeIdentifier = .authorized(system: FHIRExchangeIdentifiers.healthKitNativeRecord)
        options.role = .gatewayForOwnWrites
        options.writer = .applications(Set([Bundle.main.bundleIdentifier].compactMap(\.self)))
        options.measuresThroughput = FeatureFlags.measureExporterThroughput || FeatureFlags.recordHealthKitExportLog
        return options
    }()
}
