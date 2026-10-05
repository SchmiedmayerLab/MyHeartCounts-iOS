//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import CryptoKit
import Foundation
import GroveFHIRContract
import GroveKeychainStorage
import GroveLocalStorage
import GroveSensorKit
import GroveSensorKitFHIR
import ModelsR4
import Synchronization

// Closely related exchange state and its integration extensions intentionally share this file.
// swiftlint:disable file_types_order


/// The deployment identity of the participant a FHIR exchange concerns.
struct FHIRExchangeSubject: Sendable {
    let identity: BusinessIdentifier

    var reference: Reference {
        identity.reference(to: .patient)
    }
}


extension FirebaseConfiguration {
    /// The signed-in participant as an identifier-only logical Patient reference.
    @MainActor var fhirExchangeSubject: FHIRExchangeSubject {
        get throws {
            try FHIRExchangeSubject(identity: BusinessIdentifier(
                system: FHIRExchangeIdentifiers.participant,
                value: accountId
            ))
        }
    }
}


/// The application, host, and study facts an exchange producer freezes into every event it reserves.
struct FHIRExchangeEventFacts: Equatable, Sendable {
    struct Study: Equatable, Sendable {
        let id: String
        let revision: UInt
    }

    let applicationName: String
    let applicationBundleIdentifier: String
    let applicationVersion: String
    let applicationBuild: String?
    let hostOperatingSystemVersion: String
    let hostName: String?
    let hostManufacturer: String?
    let hostModelNumber: String?
    let study: Study?

    init(application: ApplicationDevice, host: HostDevice, study: Study?) {
        self.applicationName = application.name
        self.applicationBundleIdentifier = application.bundleIdentifier
        self.applicationVersion = application.version
        self.applicationBuild = application.build
        self.hostOperatingSystemVersion = host.operatingSystemVersion
        self.hostName = host.name
        self.hostManufacturer = host.manufacturer
        self.hostModelNumber = host.modelNumber
        self.study = study
    }

    /// The facts as they stand right now, for a reservation being made.
    static func current() throws -> Self {
        Self(
            application: try ApplicationDevice(bundle: .main),
            host: .current(),
            study: MyHeartCountsStandard.currentEnrollmentInfo.map {
                Study(id: $0.studyId, revision: $0.studyRevision)
            }
        )
    }
}


enum FHIRExchangeStateError: Error, Equatable {
    case retryContentChanged(sourceRecordID: String)
    /// The zone a SensorKit batch was first published in no longer resolves.
    case invalidPersistedTimeZone(String)
    case unsupportedSchemaVersion(UInt)
    case staleAccountGeneration(captured: Int, current: Int)
    case corruptIdentitySecret
}


/// Encrypted installation state: what a SensorKit batch's retry must reproduce.
///
/// `LocalStorage` provides encryption and atomic replacement. The store also reaches the identity secret in the
/// keychain. Every exchange event is reserved in ``FHIRExchangeLedger``, never here. Tests may use the in-memory
/// initializer, which round-trips the state through the same encoding, while every production call site uses the
/// same encrypted key.
final class FHIRExchangeStateStore: Sendable {
    fileprivate struct State: Codable, Sendable {
        struct SensorRetry: Codable, Sendable {
            let batchKey: String
            let digest: String
        }

        /// What every record of one SensorKit batch shares across its retries.
        struct SensorBatch: Codable, Sendable {
            /// The zone the batch states its bounds in, as first published.
            let timeZoneIdentifier: String
        }

        private enum CodingKeys: String, CodingKey {
            case schemaVersion
            case accountDataGeneration
            case sensorRetries
            case sensorBatches
        }

        /// The layout this build writes.
        static let currentSchemaVersion: UInt = 1

        let schemaVersion: UInt
        let accountDataGeneration: Int
        /// By batch key and source-record identifier, and for a record's supplemented evidence, a `supplement` suffix.
        var sensorRetries: [String: SensorRetry]
        /// By batch key.
        var sensorBatches: [String: SensorBatch]

        init(accountDataGeneration: Int, schemaVersion: UInt = Self.currentSchemaVersion) {
            self.schemaVersion = schemaVersion
            self.accountDataGeneration = accountDataGeneration
            self.sensorRetries = [:]
            self.sensorBatches = [:]
        }

        /// Decodes the current layout.
        ///
        /// Any other layout is never misread: it decodes empty and is refused as unsupported. That includes layout 0,
        /// which only pre-release builds wrote.
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let schemaVersion = try container.decode(UInt.self, forKey: .schemaVersion)
            guard schemaVersion == Self.currentSchemaVersion else {
                self = Self(accountDataGeneration: 0, schemaVersion: schemaVersion)
                return
            }
            self.schemaVersion = schemaVersion
            accountDataGeneration = try container.decode(Int.self, forKey: .accountDataGeneration)
            sensorRetries = try container.decode([String: SensorRetry].self, forKey: .sensorRetries)
            sensorBatches = try container.decode([String: SensorBatch].self, forKey: .sensorBatches)
        }

        /// Records the digest of `bytes` under `key` unless one is there already; `false` is drift: another digest is there.
        mutating func recordFirstSensorDigest(of bytes: Data, under key: String, batchKey: String) -> Bool {
            let digest = SHA256.hash(data: bytes).lowercaseHexString
            if let persisted = sensorRetries[key] {
                return persisted.digest == digest
            }
            sensorRetries[key] = SensorRetry(batchKey: batchKey, digest: digest)
            return true
        }
    }

    /// The bytes a retry of one SensorKit record must reproduce at its durable coordinate.
    struct SensorRetryEvidence: Sendable {
        let sourceRecordID: SensorKitSourceRecordID
        /// Grove's retry evidence of the record.
        let evidence: Data
        /// What else a retry must reproduce, digested under a key of its own beside `evidence`.
        var supplementalEvidence: Data?
    }

    /// The state as `LocalStorage` stores it: encoded, so tests exercise the same decoding.
    private final class MemoryBackend: Sendable {
        let encoded: Mutex<Data?>
        /// How often the state was loaded and stored again, as `LocalStorage.modify` would decrypt and rewrite it.
        let transactions = Mutex(0)

        init(encoded: Data?) {
            self.encoded = Mutex(encoded)
        }
    }

    private enum Backend: Sendable {
        case encrypted(LocalStorage)
        case memory(MemoryBackend)
    }

    final class SecretMemoryBackend: Sendable {
        let secret = Mutex<FHIRExchangeIdentitySecret?>(nil)
    }

    enum SecretBackend: Sendable {
        case keychain(KeychainStorage)
        case memory(SecretMemoryBackend)
    }

    static let identitySecretTag = CredentialsTag.genericPassword(
        forService: "edu.stanford.MyHeartCounts.fhirExchangeIdentity",
        storage: .keychainSynchronizable(accessGroup: nil)
    )

    private let backend: Backend
    let secrets: SecretBackend
    let accountDataGeneration: Int

    #if DEBUG
    /// The stored state as it is encoded, read without decoding it; `nil` while nothing is stored.
    var encodedStateForTesting: Data? {
        guard case .memory(let backend) = backend else {
            preconditionFailure("Reading the encoded state requires an in-memory FHIR exchange store")
        }
        return backend.encoded.withLock { $0 }
    }

    /// How often the stored state was loaded and stored again.
    var storageTransactionCountForTesting: Int {
        guard case .memory(let backend) = backend else {
            preconditionFailure("Counting storage transactions requires an in-memory FHIR exchange store")
        }
        return backend.transactions.withLock { $0 }
    }
    #endif

    init(localStorage: LocalStorage, accountDataGeneration: Int) {
        self.backend = .encrypted(localStorage)
        self.secrets = .keychain(KeychainStorage())
        self.accountDataGeneration = accountDataGeneration
    }

    #if DEBUG
    /// An isolated in-memory store for unit tests that do not load the app's dependency graph.
    init(accountDataGeneration: Int = 0) {
        self.backend = .memory(MemoryBackend(encoded: nil))
        self.secrets = .memory(SecretMemoryBackend())
        self.accountDataGeneration = accountDataGeneration
    }

    init(testingSchemaVersion: UInt, accountDataGeneration: Int = 0) throws {
        self.backend = .memory(MemoryBackend(encoded: try JSONEncoder().encode(State(
            accountDataGeneration: accountDataGeneration,
            schemaVersion: testingSchemaVersion
        ))))
        self.secrets = .memory(SecretMemoryBackend())
        self.accountDataGeneration = accountDataGeneration
    }

    /// An in-memory store whose state is stored as `encoded`, such as the JSON an earlier attempt left behind.
    init(testingEncodedState encoded: Data, accountDataGeneration: Int = 0) {
        self.backend = .memory(MemoryBackend(encoded: encoded))
        self.secrets = .memory(SecretMemoryBackend())
        self.accountDataGeneration = accountDataGeneration
    }

    /// A fresh in-memory store that shares another store's identity secret, as a second
    /// device on the same Apple Account would.
    init(accountDataGeneration: Int = 0, secretsSharedWith other: FHIRExchangeStateStore) {
        self.backend = .memory(MemoryBackend(encoded: nil))
        self.secrets = other.secrets
        self.accountDataGeneration = accountDataGeneration
    }

    private init(memoryBackend: MemoryBackend, secrets: SecretBackend, accountDataGeneration: Int) {
        self.backend = .memory(memoryBackend)
        self.secrets = secrets
        self.accountDataGeneration = accountDataGeneration
    }

    func testingView(accountDataGeneration: Int) -> FHIRExchangeStateStore {
        guard case .memory(let backend) = backend else {
            preconditionFailure("Testing views require an in-memory FHIR exchange store")
        }
        return FHIRExchangeStateStore(
            memoryBackend: backend,
            secrets: secrets,
            accountDataGeneration: accountDataGeneration
        )
    }
    #endif

    /// Persists the first digests observed at the durable SensorKit coordinates of one batch's records and rejects
    /// drift, in one transaction of the state.
    ///
    /// The records are checked in order, each record's evidence before its supplement, with the outcome of checking
    /// each in a transaction of its own: the digests first seen before the first drift are persisted, and none after
    /// it. An empty batch reads and writes nothing.
    ///
    /// A supplement is digested under a key of its own beside the record's evidence, so supplementing the evidence
    /// never fails a digest an earlier build recorded without the supplement.
    ///
    /// - throws: ``FHIRExchangeStateError/retryContentChanged(sourceRecordID:)`` naming the first record whose bytes
    ///     differ from those first seen at its coordinate.
    func verifySensorRetryDigests(_ records: [SensorRetryEvidence], batchKey: String) throws {
        guard !records.isEmpty else {
            return
        }
        let drifted = try withState { state -> SensorKitSourceRecordID? in
            for record in records {
                let evidenceKey = sensorRetryKey(batchKey: batchKey, sourceRecordID: record.sourceRecordID, supplement: false)
                guard state.recordFirstSensorDigest(of: record.evidence, under: evidenceKey, batchKey: batchKey) else {
                    return record.sourceRecordID
                }
                if let supplement = record.supplementalEvidence {
                    let supplementKey = sensorRetryKey(batchKey: batchKey, sourceRecordID: record.sourceRecordID, supplement: true)
                    guard state.recordFirstSensorDigest(of: supplement, under: supplementKey, batchKey: batchKey) else {
                        return record.sourceRecordID
                    }
                }
            }
            return nil
        }
        if let drifted {
            throw FHIRExchangeStateError.retryContentChanged(sourceRecordID: drifted.value)
        }
    }

    /// Rejects a record whose bytes could not be prepared at a SensorKit coordinate where an earlier attempt recorded
    /// them; records nothing otherwise.
    ///
    /// - throws: ``FHIRExchangeStateError/retryContentChanged(sourceRecordID:)`` when a digest was recorded at the
    ///     coordinate: the record an earlier attempt prepared, and may have exported, can no longer be reproduced.
    func verifySensorRecordWasNeverPrepared(batchKey: String, sourceRecordID: SensorKitSourceRecordID) throws {
        let key = sensorRetryKey(batchKey: batchKey, sourceRecordID: sourceRecordID, supplement: false)
        try withStorage { stored in
            let state = try validated(stored ?? State(accountDataGeneration: accountDataGeneration))
            guard state.sensorRetries[key] == nil else {
                throw FHIRExchangeStateError.retryContentChanged(sourceRecordID: sourceRecordID.value)
            }
        }
    }

    private func sensorRetryKey(batchKey: String, sourceRecordID: SensorKitSourceRecordID, supplement: Bool) -> String {
        let key = "\(batchKey)|\(sourceRecordID.value)"
        return supplement ? "\(key)|supplement" : key
    }

    /// Removes retry-only state after the complete batch is durable and its cursor is acknowledged.
    func completeSensorBatch(_ batchKey: String) throws {
        try withExistingState { state in
            state.sensorRetries = state.sensorRetries.filter { $0.value.batchKey != batchKey }
            state.sensorBatches[batchKey] = nil
        }
    }

    /// Atomically rotates all account-bound retry state.
    ///
    /// The fresh state records this store's captured account generation. A late publisher carrying
    /// an older generation fails before mutation; late cleanup-only callbacks become no-ops.
    func reset() throws {
        try withStorage { $0 = State(accountDataGeneration: accountDataGeneration) }
    }

    func sensorKitBatchKey(
        subject: FHIRExchangeSubject,
        acquisitionBatch: SensorKit.AcquisitionBatchCoordinate,
        sourceToken: String,
        deviceProductType: String
    ) -> String {
        sensorKitBatchKeyPrefix(subject: subject, sourceToken: sourceToken)
            + [deviceProductType, acquisitionBatch.stableValue].joined(separator: "|")
    }

    /// The leading components, including the trailing separator, shared by every batch key of one source.
    private func sensorKitBatchKeyPrefix(subject: FHIRExchangeSubject, sourceToken: String) -> String {
        [subject.identity.system.rawValue, subject.identity.value, sourceToken, ""].joined(separator: "|")
    }

    private func validated(_ state: State) throws -> State {
        guard state.schemaVersion == State.currentSchemaVersion else {
            throw FHIRExchangeStateError.unsupportedSchemaVersion(state.schemaVersion)
        }
        guard state.accountDataGeneration == accountDataGeneration else {
            throw FHIRExchangeStateError.staleAccountGeneration(
                captured: accountDataGeneration,
                current: state.accountDataGeneration
            )
        }
        return state
    }

    /// The one place either backend is loaded, mutated, and stored again.
    ///
    /// A state that is loaded is stored again, also when `body` leaves it unchanged.
    private func withStorage<Result>(_ body: (inout State?) throws -> Result) throws -> Result {
        switch backend {
        case .encrypted(let localStorage):
            var result: Result?
            try localStorage.modify(.fhirExchangeState) { stored in
                result = try body(&stored)
            }
            // `LocalStorage.modify` always invokes the closure or throws.
            return result! // swiftlint:disable:this force_unwrapping
        case .memory(let backend):
            // As `LocalStorage.modify` does: decode, transform, then encode again, or remove.
            backend.transactions.withLock { $0 += 1 }
            return try backend.encoded.withLock { encoded in
                var stored = try encoded.map { try JSONDecoder().decode(State.self, from: $0) }
                let result = try body(&stored)
                encoded = try stored.map { try JSONEncoder().encode($0) }
                return result
            }
        }
    }

    private func withState<Result>(_ body: (inout State) throws -> Result) throws -> Result {
        try withStorage { stored in
            var state = try validated(stored ?? State(accountDataGeneration: accountDataGeneration))
            let result = try body(&state)
            stored = state
            return result
        }
    }

    /// Mutates state that already exists; a late callback from a rotated account is a no-op.
    private func withExistingState(_ body: (inout State) throws -> Void) throws {
        try withStorage { stored in
            guard var state = stored else {
                return
            }
            guard state.schemaVersion == State.currentSchemaVersion else {
                throw FHIRExchangeStateError.unsupportedSchemaVersion(state.schemaVersion)
            }
            guard state.accountDataGeneration == accountDataGeneration else {
                return
            }
            try body(&state)
            stored = state
        }
    }
}


extension FHIRExchangeStateStore {
    /// The zone a SensorKit batch states its bounds in: `current` when the batch is first seen, persisted with its
    /// retry state, so every redelivery of the batch states the same bounds.
    ///
    /// - throws: ``FHIRExchangeStateError/invalidPersistedTimeZone(_:)`` when the persisted zone no longer resolves;
    ///     the batch can then never be redelivered as it was first published.
    func sensorBatchTimeZone(_ batchKey: String, current: TimeZone = .current) throws -> TimeZone {
        let identifier = try withState { state in
            if let persisted = state.sensorBatches[batchKey] {
                return persisted.timeZoneIdentifier
            }
            state.sensorBatches[batchKey] = State.SensorBatch(timeZoneIdentifier: current.identifier)
            return current.identifier
        }
        guard let timeZone = TimeZone(identifier: identifier) else {
            throw FHIRExchangeStateError.invalidPersistedTimeZone(identifier)
        }
        return timeZone
    }

    /// Removes the retry-only state of every batch of one SensorKit source.
    ///
    /// Only valid once the source's pending batches were abandoned: their records are fetched again
    /// under fresh acquisition coordinates, so none of the removed state can be needed by a retry.
    func abandonSensorBatches(subject: FHIRExchangeSubject, sourceToken: String) throws {
        let batchKeyPrefix = sensorKitBatchKeyPrefix(subject: subject, sourceToken: sourceToken)
        try withExistingState { state in
            state.sensorRetries = state.sensorRetries.filter { !$0.value.batchKey.hasPrefix(batchKeyPrefix) }
            state.sensorBatches = state.sensorBatches.filter { !$0.key.hasPrefix(batchKeyPrefix) }
        }
    }
}


extension LocalStorageKeys {
    fileprivate static let fhirExchangeState = LocalStorageKey<FHIRExchangeStateStore.State>(
        "edu.stanford.MyHeartCounts.fhir.exchange-state.v0"
    )
}
