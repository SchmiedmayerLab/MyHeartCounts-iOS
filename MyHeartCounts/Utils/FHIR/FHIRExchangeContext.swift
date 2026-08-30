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
        Reference(
            identifier: identity.fhirIdentifier,
            type: FHIRPrimitive(FHIRURI(stringLiteral: "Patient"))
        )
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


/// Immutable event-time facts retained so an exact retry reproduces the original graph.
struct PersistedFHIRExchangeEvent: Codable, Equatable, Sendable {
    let sequence: UInt64
    let recordedAt: Date
    let sourceTimeZoneIdentifier: String
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


struct FHIRExchangeEventFacts: Sendable {
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


enum FHIRExchangeRuntimeFacts {
    static var host: HealthKitHostDevice {
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
    }

    private static var machineIdentifier: String? {
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
    case exhaustedEventSequence
    case retryContentChanged(sourceRecordID: String)
    case invalidPersistedTimeZone(String)
    case unsupportedSchemaVersion(UInt)
    case staleAccountGeneration(captured: Int, current: Int)
}


/// Encrypted installation state for deterministic Grove exchange contexts.
///
/// `LocalStorage` provides encryption and atomic replacement. Tests may use the in-memory
/// initializer, while every production call site uses the same encrypted key.
final class FHIRExchangeStateStore: @unchecked Sendable { // swiftlint:disable:this type_body_length
    fileprivate struct State: Codable, Sendable {
        struct SensorRetry: Codable, Sendable {
            let batchKey: String
            let digest: String
        }

        let schemaVersion: UInt
        let accountDataGeneration: Int
        let producerInstance: UUID
        let identityKey: Data
        var nextEventSequence: UInt64
        var events: [String: PersistedFHIRExchangeEvent]
        var sensorRetries: [String: SensorRetry]

        init(accountDataGeneration: Int, schemaVersion: UInt = 0) {
            var generator = SystemRandomNumberGenerator()
            self.schemaVersion = schemaVersion
            self.accountDataGeneration = accountDataGeneration
            self.producerInstance = UUID()
            self.identityKey = Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
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

    private let backend: Backend
    private let accountDataGeneration: Int

    #if DEBUG
    var hasPersistedStateForTesting: Bool {
        get throws {
            switch backend {
            case .encrypted(let localStorage):
                try localStorage.load(.fhirExchangeState) != nil
            case .memory(let backend):
                backend.state.withLock { $0 != nil }
            }
        }
    }
    #endif

    init(localStorage: LocalStorage, accountDataGeneration: Int) {
        self.backend = .encrypted(localStorage)
        self.accountDataGeneration = accountDataGeneration
    }

    #if DEBUG
    /// An isolated in-memory store for unit tests that do not load the app's dependency graph.
    init(accountDataGeneration: Int = 0) {
        self.backend = .memory(MemoryBackend(nil))
        self.accountDataGeneration = accountDataGeneration
    }

    init(testingSchemaVersion: UInt, accountDataGeneration: Int = 0) {
        self.backend = .memory(MemoryBackend(State(
            accountDataGeneration: accountDataGeneration,
            schemaVersion: testingSchemaVersion
        )))
        self.accountDataGeneration = accountDataGeneration
    }

    private init(memoryBackend: MemoryBackend, accountDataGeneration: Int) {
        self.backend = .memory(memoryBackend)
        self.accountDataGeneration = accountDataGeneration
    }

    func testingView(accountDataGeneration: Int) -> FHIRExchangeStateStore {
        guard case .memory(let backend) = backend else {
            preconditionFailure("Testing views require an in-memory FHIR exchange store")
        }
        return FHIRExchangeStateStore(
            memoryBackend: backend,
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
            guard state.nextEventSequence < UInt64.max else {
                throw FHIRExchangeStateError.exhaustedEventSequence
            }
            let event = PersistedFHIRExchangeEvent(
                sequence: state.nextEventSequence,
                recordedAt: recordedAt,
                sourceTimeZoneIdentifier: sourceTimeZone.identifier,
                applicationToken: facts.applicationToken,
                applicationName: facts.applicationName,
                applicationVersion: facts.applicationVersion,
                applicationBuild: facts.applicationBuild,
                hostToken: facts.hostToken,
                hostOperatingSystemVersion: facts.hostOperatingSystemVersion,
                hostName: facts.hostName,
                hostManufacturer: facts.hostManufacturer,
                hostModelNumber: facts.hostModelNumber,
                researchStudyIDs: facts.researchStudyIDs
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
        let digest = Data(SHA256.hash(data: sourceBytes)).lowercaseHexString
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

    /// Removes a HealthKit reservation after the source cursor durably acknowledges its graph.
    ///
    /// Persisting a Bundle is not sufficient: a crash before the source cursor commit still causes
    /// exact redelivery and must reuse the original event facts.
    func completeHealthKitEvent(_ eventKey: String) throws {
        try completeHealthKitEvents(CollectionOfOne(eventKey))
    }

    /// Atomically removes every reservation for one source-acknowledged HealthKit batch.
    func completeHealthKitEvents(_ eventKeys: some Sequence<String>) throws {
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
        switch backend {
        case .encrypted(let localStorage):
            try localStorage.modify(.fhirExchangeState) { stored in
                stored = State(accountDataGeneration: accountDataGeneration)
            }
        case .memory(let backend):
            backend.state.withLock {
                $0 = State(accountDataGeneration: accountDataGeneration)
            }
        }
    }

    func healthKitEventKey(
        subject: FHIRExchangeSubject,
        sourceType: String,
        nativeRecordID: UUID
    ) -> String {
        "healthkit|\(subject.identity.systemValue)|\(subject.identity.value)|\(sourceType)|\(nativeRecordID.uuidString.lowercased())"
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

    func identityScope() throws -> PseudonymousIdentityScope {
        let state = try stateSnapshot()
        return try PseudonymousIdentityScope(
            systems: FHIRExchangeIdentifiers.pseudonymousSystems,
            keyID: "installation",
            epoch: 1,
            key: state.identityKey
        )
    }

    func repositoryScope(_ source: FHIRExchangeIdentifiers.SourceRepository) throws -> BusinessIdentifier {
        let state = try stateSnapshot()
        return try BusinessIdentifier(
            system: FHIRExchangeIdentifiers.repository,
            value: "\(source.rawValue):\(state.producerInstance.uuidString.lowercased())"
        )
    }

    /// Reads stable installation facts without rewriting the encrypted ledger.
    ///
    /// The first read still initializes the state atomically so repeated read-only calls cannot
    /// observe different producer identities.
    private func stateSnapshot() throws -> State {
        switch backend {
        case .encrypted(let localStorage):
            if let state = try localStorage.load(.fhirExchangeState) {
                return try validated(state)
            }
            return try withState { $0 }
        case .memory(let backend):
            return try backend.state.withLock { stored in
                let state = stored ?? State(accountDataGeneration: accountDataGeneration)
                stored = state
                return try validated(state)
            }
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

    private func withState<Result>(_ body: (inout State) throws -> Result) throws -> Result {
        switch backend {
        case .encrypted(let localStorage):
            var result: Result?
            try localStorage.modify(.fhirExchangeState) { stored in
                var state = try validated(
                    stored ?? State(accountDataGeneration: accountDataGeneration)
                )
                result = try body(&state)
                stored = state
            }
            // `LocalStorage.modify` always invokes the closure or throws.
            return result! // swiftlint:disable:this force_unwrapping
        case .memory(let backend):
            return try backend.state.withLock { stored in
                var state = try validated(
                    stored ?? State(accountDataGeneration: accountDataGeneration)
                )
                let result = try body(&state)
                stored = state
                return result
            }
        }
    }

    private func withExistingState(_ body: (inout State) throws -> Void) throws {
        switch backend {
        case .encrypted(let localStorage):
            try localStorage.modify(.fhirExchangeState) { stored in
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
        case .memory(let backend):
            try backend.state.withLock { stored in
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
}


extension LocalStorageKeys {
    fileprivate static let fhirExchangeState = LocalStorageKey<FHIRExchangeStateStore.State>(
        "edu.stanford.MyHeartCounts.fhir.exchange-state.v0"
    )
}


extension Data {
    fileprivate var lowercaseHexString: String {
        let alphabet = Array("0123456789abcdef".utf8)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(count * 2)
        for byte in self {
            bytes.append(alphabet[Int(byte >> 4)])
            bytes.append(alphabet[Int(byte & 0x0F)])
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
