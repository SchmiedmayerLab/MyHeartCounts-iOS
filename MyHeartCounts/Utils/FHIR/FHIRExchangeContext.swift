//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import CryptoKit
import Darwin
import Foundation
import GroveFHIRContract
import GroveHealthKitFHIR
import GroveKeychainStorage
import GroveLocalStorage
import GroveSensorKit
import GroveSensorKitFHIR
import HealthKit
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


/// The application and host facts one exchange event is composed from.
struct FHIRExchangeEventFacts: Codable, Equatable, Sendable {
    /// The facts as they stand right now, for a reservation being made.
    static var current: Self {
        let application = HealthKitApplication.main
        let host = FHIRExchangeRuntimeFacts.host
        return Self(
            applicationToken: application.bundleIdentifier,
            applicationName: application.name,
            applicationVersion: application.version,
            applicationBuild: application.build,
            hostToken: host.sourceDeviceToken,
            hostOperatingSystemVersion: host.operatingSystemVersion,
            hostName: host.name,
            hostManufacturer: host.manufacturer,
            hostModelNumber: host.modelNumber,
            researchStudyIDs: FHIRExchangeIdentifiers.currentResearchStudyIDs()
        )
    }

    let applicationToken: String
    let applicationName: String
    let applicationVersion: String?
    let applicationBuild: String?
    let hostToken: String
    let hostOperatingSystemVersion: String
    let hostName: String?
    let hostManufacturer: String?
    let hostModelNumber: String?
    let researchStudyIDs: [String]
}


/// Immutable event-time facts retained so an exact retry reproduces the original graph.
struct PersistedFHIRExchangeEvent: Codable, Equatable, Sendable {
    let sequence: UInt64
    let recordedAt: Date
    let sourceTimeZoneIdentifier: String
    let facts: FHIRExchangeEventFacts
}


enum FHIRExchangeRuntimeFacts {
    static let host: HealthKitHostDevice = {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return HealthKitHostDevice(
            sourceDeviceToken: "current-converter-host",
            operatingSystemVersion: [
                version.majorVersion,
                version.minorVersion,
                version.patchVersion
            ].map(String.init).joined(separator: "."),
            manufacturer: "Apple",
            modelNumber: machineIdentifier
        )
    }()

    private static var machineIdentifier: String? {
        // A simulator's uname reports the host Mac, which is not the device the app runs as.
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"],
           !simulated.isEmpty {
            return simulated
        }
        var systemInfo = utsname()
        guard uname(&systemInfo) == 0 else {
            return nil
        }
        let capacity = MemoryLayout.size(ofValue: systemInfo.machine)
        return withUnsafePointer(to: &systemInfo.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) {
                String(validatingCString: $0)
            }
        }.flatMap { $0.isEmpty ? nil : $0 }
    }
}


enum FHIRExchangeStateError: Error, Equatable {
    case retryContentChanged(sourceRecordID: String)
    case invalidPersistedTimeZone(String)
    case unsupportedSchemaVersion(UInt)
    case staleAccountGeneration(captured: Int, current: Int)
    case corruptIdentitySecret
}


/// Encrypted installation state for deterministic Grove exchange contexts.
///
/// `LocalStorage` provides encryption and atomic replacement. Tests may use the in-memory
/// initializer, while every production call site uses the same encrypted key.
final class FHIRExchangeStateStore: Sendable {
    fileprivate struct State: Codable, Sendable {
        struct SensorRetry: Codable, Sendable {
            let batchKey: String
            let digest: String
        }

        let schemaVersion: UInt
        let accountDataGeneration: Int
        let producerInstance: UUID
        var nextEventSequence: UInt64
        var events: [String: PersistedFHIRExchangeEvent]
        var sensorRetries: [String: SensorRetry]

        init(accountDataGeneration: Int, schemaVersion: UInt = 0) {
            self.schemaVersion = schemaVersion
            self.accountDataGeneration = accountDataGeneration
            self.producerInstance = UUID()
            self.nextEventSequence = 1
            self.events = [:]
            self.sensorRetries = [:]
        }
    }

    private final class MemoryBackend: Sendable {
        let state: Mutex<State?>

        init(_ state: State?) {
            self.state = Mutex(state)
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
    private let accountDataGeneration: Int

    #if DEBUG
    var hasPersistedStateForTesting: Bool {
        get throws {
            try withStorage(readOnly: true) { $0 != nil }
        }
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
        self.backend = .memory(MemoryBackend(nil))
        self.secrets = .memory(SecretMemoryBackend())
        self.accountDataGeneration = accountDataGeneration
    }

    init(testingSchemaVersion: UInt, accountDataGeneration: Int = 0) {
        self.backend = .memory(MemoryBackend(State(
            accountDataGeneration: accountDataGeneration,
            schemaVersion: testingSchemaVersion
        )))
        self.secrets = .memory(SecretMemoryBackend())
        self.accountDataGeneration = accountDataGeneration
    }

    /// A fresh in-memory ledger that shares another store's identity secret, as a second
    /// device on the same Apple Account would.
    init(accountDataGeneration: Int = 0, secretsSharedWith other: FHIRExchangeStateStore) {
        self.backend = .memory(MemoryBackend(nil))
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

    func event(
        key: String,
        recordedAt: Date,
        sourceTimeZone: TimeZone = .current,
        facts: FHIRExchangeEventFacts
    ) throws -> PersistedFHIRExchangeEvent {
        try withState { state in
            if let persisted = state.events[key] {
                return persisted
            }
            let event = PersistedFHIRExchangeEvent(
                sequence: state.nextEventSequence,
                recordedAt: recordedAt,
                sourceTimeZoneIdentifier: sourceTimeZone.identifier,
                facts: facts
            )
            state.nextEventSequence += 1
            state.events[key] = event
            return event
        }
    }

    /// Persists the first digest observed at a durable SensorKit coordinate and rejects drift.
    func verifySensorRetryDigest(
        _ sourceBytes: Data,
        batchKey: String,
        sourceRecordID: SensorKitSourceRecordID
    ) throws {
        let key = "\(batchKey)|\(sourceRecordID.value)"
        let digest = SHA256.hash(data: sourceBytes).lowercaseHexString
        try withState { state in
            if let persisted = state.sensorRetries[key] {
                guard persisted.digest == digest else {
                    throw FHIRExchangeStateError.retryContentChanged(sourceRecordID: sourceRecordID.value)
                }
            } else {
                state.sensorRetries[key] = State.SensorRetry(batchKey: batchKey, digest: digest)
            }
        }
    }

    /// Removes retry-only state after the complete batch is durable and its cursor is acknowledged.
    func completeSensorBatch(_ batchKey: String) throws {
        try withExistingState { state in
            state.sensorRetries = state.sensorRetries.filter { $0.value.batchKey != batchKey }
            state.events = state.events.filter { !$0.key.hasPrefix("sensorkit|\(batchKey)|") }
        }
    }

    /// Atomically removes reservations whose graphs the source has durably acknowledged.
    ///
    /// Persisting a Bundle is not sufficient: a crash before the source cursor commit still causes
    /// exact redelivery and must reuse the original event facts.
    func completeExchangeEvents(_ eventKeys: some Sequence<String>) throws {
        let eventKeys = Set(eventKeys)
        guard !eventKeys.isEmpty else {
            return
        }
        try withExistingState { state in
            state.events = state.events.filter { !eventKeys.contains($0.key) }
        }
    }

    /// Atomically rotates all account-bound exchange identity, retry, and event state.
    ///
    /// The fresh state records this store's captured account generation. A late publisher carrying
    /// an older generation fails before mutation; late cleanup-only callbacks become no-ops.
    func reset() throws {
        try withStorage { $0 = State(accountDataGeneration: accountDataGeneration) }
    }

    func healthKitEventKey(
        subject: FHIRExchangeSubject,
        sourceType: String,
        nativeRecordID: UUID
    ) -> String {
        "healthkit|\(subject.identity.systemValue)|\(subject.identity.value)|\(sourceType)|\(nativeRecordID.uuidString.lowercased())"
    }

    func questionnaireEventKey(subject: FHIRExchangeSubject, responseID: String) -> String {
        "questionnaire|\(subject.identity.systemValue)|\(subject.identity.value)|\(responseID)"
    }

    func sensorKitBatchKey(
        subject: FHIRExchangeSubject,
        acquisitionBatch: SensorKit.AcquisitionBatchCoordinate,
        sourceToken: String,
        deviceProductType: String
    ) -> String {
        [
            subject.identity.systemValue,
            subject.identity.value,
            sourceToken,
            deviceProductType,
            acquisitionBatch.stableValue
        ].joined(separator: "|")
    }

    func sensorKitEventKey(batchKey: String, sourceRecordID: SensorKitSourceRecordID) -> String {
        "sensorkit|\(batchKey)|\(sourceRecordID.value)"
    }

    func eventIdentifier(for event: PersistedFHIRExchangeEvent) throws -> ExchangeEventIdentifier {
        let state = try stateSnapshot()
        return try ExchangeEventIdentifier(
            system: FHIRExchangeIdentifiers.event,
            producerInstance: state.producerInstance,
            sequence: event.sequence
        )
    }


    /// Reads stable installation facts without rewriting the encrypted ledger.
    ///
    /// The first read still initializes the state atomically so repeated read-only calls cannot
    /// observe different producer identities.
    private func stateSnapshot() throws -> State {
        try withStorage(readOnly: true) { stored in
            let state = try validated(stored ?? State(accountDataGeneration: accountDataGeneration))
            stored = state
            return state
        }
    }

    private func validated(_ state: State) throws -> State {
        guard state.schemaVersion == 0 else {
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
    /// `readOnly` serves already-initialized state without a write-back, so repeated fact reads do
    /// not rewrite the encrypted ledger.
    private func withStorage<Result>(
        readOnly: Bool = false,
        _ body: (inout State?) throws -> Result
    ) throws -> Result {
        switch backend {
        case .encrypted(let localStorage):
            if readOnly, let loaded = try localStorage.load(.fhirExchangeState) {
                var stored: State? = loaded
                return try body(&stored)
            }
            var result: Result?
            try localStorage.modify(.fhirExchangeState) { stored in
                result = try body(&stored)
            }
            // `LocalStorage.modify` always invokes the closure or throws.
            return result! // swiftlint:disable:this force_unwrapping
        case .memory(let backend):
            return try backend.state.withLock { try body(&$0) }
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
            guard state.schemaVersion == 0 else {
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


extension LocalStorageKeys {
    fileprivate static let fhirExchangeState = LocalStorageKey<FHIRExchangeStateStore.State>(
        "edu.stanford.MyHeartCounts.fhir.exchange-state.v0"
    )
}
