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
import MyHeartCountsShared
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

    /// The identity scope this store's secret keys for `subject`, as every exporter factory derives it.
    func identityScope(subject: FHIRExchangeSubject) throws -> OpaqueIdentityScope {
        try Self.identityScope(of: identitySecret(), subject: subject)
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

    /// What `batchKey`'s records state on a delivery while `current` holds the zone, instant and facts of the moment.
    func sensorBatchFacts(_ batchKey: String, current: SensorBatchFacts) throws -> SensorBatchFacts {
        try sensorBatchFacts(
            batchKey,
            currentTimeZone: current.timeZone,
            conversionInstant: current.conversionInstant,
            conversionFacts: current.conversionFacts,
            devices: current.devices
        )
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
        let upload = SensorKitRecordUpload(
            ordinal: ordinal,
            sampleCount: 1,
            timeRange: SensorKitPublicationHarness.start..<SensorKitPublicationHarness.start,
            sidecar: nil,
            retryEvidence: evidence
        ) { _, _, _ in
            // Never built: checking a record's evidence only derives its identity.
            throw CancellationError()
        }
        return try #require(try sourceRecordIDs(of: [upload]).first)
    }
}


/// What a publication under test staged, in order.
final class RecordedSensorKitUploads: Sendable {
    /// One batch file staged under its remote path, with its exact bytes.
    struct StagedFile: Equatable {
        let path: String
        let bytes: Data
        /// The metadata the file is uploaded with.
        let metadata: [String: String]
    }

    struct StageFailure: Error {}

    private let files = Mutex<[StagedFile]>([])
    /// Whether staging a file fails, after the file was recorded.
    private let failsStaging: Bool

    var all: [StagedFile] {
        files.withLock { $0 }
    }

    /// The entries of the staged archives, in staging order and, within an archive, in archive order.
    var entries: [ZipArchive.Entry] {
        get throws {
            try all.flatMap { try ZipArchive.entries(in: $0.bytes) }
        }
    }

    /// The staged archives, in staging order.
    var archives: [UploadBatchArchive.Reader] {
        get throws {
            try all.map { try UploadBatchArchive.Reader($0.bytes) }
        }
    }

    /// The one Bundle of each staged archive, in staging order.
    var bundles: [Data] {
        get throws {
            try archives.map { try $0.bundle() }
        }
    }

    /// The records the staged Bundles carry, in staging order and, within a Bundle, in entry order.
    var records: [ExchangeRecord] {
        get throws {
            try bundles.flatMap { try packedRecords(in: $0) }
        }
    }

    /// Each of ``records`` as a one-record Bundle.
    var graphs: [Data] {
        get throws {
            try records.map(\.json)
        }
    }

    /// The recordings the staged archives carry, by their path within their archive.
    var recordings: [String: Data] {
        get throws {
            var recordings: [String: Data] = [:]
            for archive in try archives {
                for path in archive.recordingPaths {
                    recordings[path] = try archive.recording(at: path)
                }
            }
            return recordings
        }
    }

    var uploader: SensorKitBatchUploader {
        ._custom { file, category, _, metadata in
            let bytes = try Data(contentsOf: file)
            self.files.withLock {
                $0.append(StagedFile(path: category.remotePath(for: file.lastPathComponent), bytes: bytes, metadata: metadata))
            }
            if self.failsStaging {
                throw StageFailure()
            }
            // Staging takes the file, as the managed file upload does.
            try FileManager.default.removeItem(at: file)
        }
    }

    init(failingStaging: Bool = false) {
        self.failsStaging = failingStaging
    }
}


/// A source device whose description is fixed, so the source-record identifiers derived from its batches are known answers.
class PinnedSensorKitDevice: SRDevice, @unchecked Sendable {
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


/// The pinned device after its owner renamed it and updated its OS: the same unit, so its batches keep their keys.
final class UpdatedSensorKitDevice: PinnedSensorKitDevice, @unchecked Sendable {
    override var name: String {
        "Renamed iPhone"
    }
    override var systemVersion: String {
        "27.0"
    }
}


extension SensorKit.SourceDeviceInfo {
    /// A peripheral stating every fact, each with a value of its own.
    static func pinnedPeripheral(firmwareVersion: String = "5.1") -> Self {
        Self(
            localIdentifier: "peripheral-7",
            manufacturer: "Example Audio",
            model: "Ear One",
            hardwareVersion: "2",
            firmwareVersion: firmwareVersion
        )
    }
}


extension SensorBatchDevices {
    /// The devices of a batch `device` recorded and `sources` supplied.
    static func testing(device: SRDevice = PinnedSensorKitDevice(), sources: [SensorKit.SourceDeviceInfo] = []) -> Self {
        Self(SensorKit.BatchInfo(
            timeRange: SensorKitPublicationHarness.start..<SensorKitPublicationHarness.start,
            device: SensorKit.DeviceInfo(device),
            sourceDevices: sources,
            acquisitionBatch: SensorKit.AcquisitionBatchCoordinate(
                cursorTimestamp: SensorKitPublicationHarness.start,
                resetGeneration: 2,
                sequence: 1
            )
        ))
    }
}


/// One SensorKit source's batch as production publishes it, from the pinned device, over an in-memory store of the
/// current account generation.
struct SensorKitPublicationHarness {
    static let start = Date(timeIntervalSince1970: 1_788_000_000.125)

    let sensor: any AnySensor
    let store: FHIRExchangeStateStore
    /// The acquisition sequence of the batch, from which its records' identities derive.
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
        self.sensor = sensor
        self.store = store ?? FHIRExchangeStateStore(accountDataGeneration: LocalPreferencesStore.standard[.accountDataGeneration])
        self.sequence = sequence
    }

    /// The batch's publication, writing to `uploads`.
    ///
    /// - Parameters:
    ///   - instant: The conversion instant, if this is the batch's first delivery; a redelivery repeats the first one's.
    ///   - streamPartition: The batch coordinate's partition, which a fresh anchor, such as a reinstall's, mints anew.
    ///   - facts: The conversion facts, if this is the batch's first delivery; `nil` states the default test facts.
    ///   - device: The device SensorKit states, if this is the batch's first delivery.
    ///   - sourceDevices: The peripherals SensorKit states, if this is the batch's first delivery.
    func publication(
        uploads: RecordedSensorKitUploads,
        at instant: Date = Self.start,
        streamPartition: UInt64 = 0,
        facts: MyHeartCounts::ConversionFacts? = nil,
        device: SRDevice = PinnedSensorKitDevice(),
        sourceDevices: [SensorKit.SourceDeviceInfo] = []
    ) throws -> SensorKitBatchPublication {
        let subject = try subject
        return try SensorKitBatchPublication(
            sensor: sensor,
            batchInfo: SensorKit.BatchInfo(
                timeRange: Self.start..<Self.start.addingTimeInterval(600),
                device: SensorKit.DeviceInfo(device),
                sourceDevices: sourceDevices,
                acquisitionBatch: SensorKit.AcquisitionBatchCoordinate(
                    streamPartition: streamPartition,
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
            uploader: uploads.uploader,
            conversionInstant: instant,
            currentFacts: {
                try facts ?? .testing()
            }
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
