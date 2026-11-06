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
@testable import MyHeartCounts
import Synchronization


/// What one export call delivered, by source sample.
struct ExchangeDelivery {
    var records: [UUID: ExchangeRecord] = [:]

    /// Each record's bytes, as staging stores them: a one-record Bundle.
    var graphs: [UUID: Data] {
        records.mapValues(\.json)
    }

    var versions: [UUID: RecordVersion] {
        records.mapValues(\.version)
    }
}


/// One installation's exchange inputs: its identity secret, and the fixed facts, subject and samples tests convert.
///
/// A record version is keyed by the identity secret and the subject, and digests the Provenance, which states the facts
/// and the conversion instant, so two deliveries only compare under one `identity`, subject, set of facts and instant.
struct ExchangeHarness {
    static let start = Date(timeIntervalSince1970: 1_788_000_000)

    /// The participant the exchange tests convert for.
    static var subject: FHIRExchangeSubject {
        get throws {
            try participant("exchange-participant")
        }
    }

    /// A second participant, for tests of what must stay apart between two subjects.
    static var otherSubject: FHIRExchangeSubject {
        get throws {
            try participant("exchange-participant-2")
        }
    }

    let identity: FHIRExchangeStateStore

    init(identity: FHIRExchangeStateStore = FHIRExchangeStateStore()) {
        self.identity = identity
    }

    private static func participant(_ value: String) throws -> FHIRExchangeSubject {
        try FHIRExchangeSubject(identity: BusinessIdentifier(system: FHIRExchangeIdentifiers.participant, value: value))
    }

    /// A distinct step-count sample per index.
    static func steps(_ index: Int) -> HKQuantitySample {
        let sampleStart = start.addingTimeInterval(TimeInterval(index) * 60)
        return HKQuantitySample(
            type: HKQuantityType(.stepCount),
            quantity: HKQuantity(unit: .count(), doubleValue: Double(index + 1)),
            start: sampleStart,
            end: sampleStart.addingTimeInterval(30)
        )
    }

    /// An exporter of `subject`, by default ``subject``, under the default test facts.
    func exporter(subject: FHIRExchangeSubject? = nil) throws -> HealthKitFHIRExporter {
        try identity.healthKitExporter(subject: subject ?? Self.subject, facts: .testing())
    }
}


extension HealthKitFHIRExporter {
    func deliver(_ samples: [HKSample], at instant: Date = ExchangeHarness.start) async throws -> ExchangeDelivery {
        var delivery = ExchangeDelivery()
        try await export(samples, at: instant) { export in
            if let record = export.record {
                delivery.records[export.source.uuid] = record
            }
        }
        return delivery
    }
}


extension FHIRExchangeStateStore {
    /// Whether this in-memory store holds an identity secret, which its first read mints.
    var holdsIdentitySecret: Bool {
        get throws {
            guard case .memory(let secrets) = secrets else {
                throw CancellationError()
            }
            return secrets.secret.withLock { $0 != nil }
        }
    }
}


extension HealthUploadBatch {
    /// A Bundle of several records fails, and so does the one-record Bundle of each Provenance in `doomed`.
    static func failingBundles(alone doomed: Set<String> = []) -> MakeBundle {
        { packer, packedAt throws(ExchangeGraphError) in
            guard packer.recordCount == 1 else {
                throw .invalidEntries("forced")
            }
            let graph = try packer.bundle(packedAt: packedAt)
            guard doomed.isDisjoint(with: graph.provenanceFullURLs) else {
                throw .invalidEntries("forced")
            }
            return graph
        }
    }
}


/// The records a packed Bundle carries, in entry order.
///
/// Packing keeps every record's version, but not its bytes: the Bundle states each shared node once, so a record read
/// back here lists its entries in the Bundle's order, and its `json` can differ from the `json` it was staged as.
func packedRecords(in json: Data, kind: ExchangeGraph.Kind = .active) throws -> [ExchangeRecord] {
    try ExchangeGraph(validating: json, kind: kind).records()
}
