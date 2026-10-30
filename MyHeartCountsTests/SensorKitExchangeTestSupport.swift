//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFHIRContract
import GroveFoundation
import GroveSensorKit
import GroveSensorKitFHIR
@testable import MyHeartCounts
import SensorKit
import Synchronization
import Testing

// The SensorKit exchange tests' shared fixtures intentionally live in one file.
// swiftlint:disable file_types_order


extension FHIRExchangeStateStore {
    /// The secret every pinned identifier is minted under.
    private static let knownIdentitySecret = Data("""
        {
          "key": "AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA=",
          "storeID": "3F8A1D2E-4B5C-6D7E-8F90-A1B2C3D4E5F6",
          "epoch": 1
        }
    """.utf8)

    /// The identity scope this store's secret keys, as every exporter factory derives it.
    func identityScope() throws -> OpaqueIdentityScope {
        try Self.identityScope(of: identitySecret())
    }

    /// The repository one source's records live in, under this store's secret, as every exporter factory derives it.
    func repositoryScope(
        _ source: FHIRExchangeIdentifiers.SourceRepository,
        subject: FHIRExchangeSubject
    ) throws -> BusinessIdentifier {
        try Self.repositoryScope(source, subject: subject, secret: identitySecret())
    }

    /// Makes this in-memory store mint every identity under the known secret, decoded as the keychain's is.
    func useKnownIdentitySecret() throws {
        guard case .memory(let secrets) = secrets else {
            Issue.record("An in-memory store must carry an in-memory secret backend")
            return
        }
        let secret = try JSONDecoder().decode(FHIRExchangeIdentitySecret.self, from: Self.knownIdentitySecret)
        secrets.secret.withLock { $0 = secret }
    }

    /// Checks one record's retry evidence, as a batch of only that record is checked.
    func verifySensorRetryDigest(_ evidence: Data, batchKey: String, sourceRecordID: SensorKitSourceRecordID) throws {
        try verifySensorRetryDigests([SensorRetryEvidence(sourceRecordID: sourceRecordID, evidence: evidence)], batchKey: batchKey)
    }
}


extension SensorKitBatchPublication {
    /// The identity of the record at `ordinal`, once `evidence` is checked as publishing a batch of only that record
    /// checks it.
    func sourceRecordID(ordinal: Int, evidence: Data) throws -> SensorKitSourceRecordID {
        let upload = SensorKitRecordUpload(ordinal: ordinal, sidecar: nil, retryEvidence: evidence) { _, _, _ in
            // Never built: checking a record's evidence only derives its identity.
            throw CancellationError()
        }
        return try #require(try sourceRecordIDs(of: [upload]).first)
    }
}


/// A source device whose description is fixed, so the source-record identifiers derived from its batches are known answers.
final class PinnedSensorKitDevice: SRDevice, @unchecked Sendable {
    override var name: String {
        "Pinned iPhone"
    }
    override var model: String {
        "iPhone"
    }
    override var systemName: String {
        "iOS"
    }
    override var systemVersion: String {
        "26.0"
    }
    override var productType: String {
        "iPhone18,1"
    }
}


/// One SensorKit source's batch as production publishes it, from the pinned device, over an in-memory store and ledger
/// of the current account generation.
struct SensorKitPublicationHarness {
    static let start = Date(timeIntervalSince1970: 1_788_000_000.125)

    let sensor: any AnySensor
    let store: FHIRExchangeStateStore
    let ledger: FHIRExchangeLedger
    /// The acquisition sequence of the batch. Each suite takes its own, so no two suites stage a sidecar under one name.
    let sequence: UInt64

    var subject: FHIRExchangeSubject {
        get throws {
            try FHIRExchangeSubject(identity: BusinessIdentifier(
                system: FHIRExchangeIdentifiers.participant,
                value: "sensorkit-test-participant"
            ))
        }
    }

    init(sensor: any AnySensor, sequence: UInt64, store: FHIRExchangeStateStore? = nil) {
        let accountDataGeneration = LocalPreferencesStore.standard[.accountDataGeneration]
        self.sensor = sensor
        self.store = store ?? FHIRExchangeStateStore(accountDataGeneration: accountDataGeneration)
        self.ledger = .forTesting(accountDataGeneration: accountDataGeneration)
        self.sequence = sequence
    }

    /// The batch's publication, writing to `uploads` and reserving new events at `instant`.
    func publication(uploads: RecordedSensorKitUploads, at instant: Date = Self.start) throws -> SensorKitBatchPublication {
        let subject = try subject
        return try SensorKitBatchPublication(
            sensor: sensor,
            batchInfo: SensorKit.BatchInfo(
                timeRange: Self.start..<Self.start.addingTimeInterval(600),
                device: SensorKit.DeviceInfo(PinnedSensorKitDevice()),
                acquisitionBatch: SensorKit.AcquisitionBatchCoordinate(
                    cursorTimestamp: Self.start,
                    resetGeneration: 2,
                    sequence: sequence
                )
            ),
            subject: subject,
            destination: FHIRExchangeDestination(
                accountDataGeneration: store.accountDataGeneration,
                accountID: subject.identity.value
            ),
            stateStore: store,
            ledger: ledger,
            uploader: uploads.uploader,
            conversionInstant: instant
        )
    }
}


/// Every identifier a graph states anywhere, as its system and value.
func statedIdentifiers(in json: Data) throws -> [(system: String, value: String)] {
    func collect(_ node: Any, into identifiers: inout [(system: String, value: String)]) {
        if let object = node as? [String: Any] {
            if let system = object["system"] as? String, let value = object["value"] as? String {
                identifiers.append((system, value))
            }
            for key in object.keys.sorted() {
                collect(object[key] as Any, into: &identifiers)
            }
        } else if let array = node as? [Any] {
            for element in array {
                collect(element, into: &identifiers)
            }
        }
    }
    var identifiers: [(system: String, value: String)] = []
    collect(try JSONSerialization.jsonObject(with: json), into: &identifiers)
    return identifiers
}
