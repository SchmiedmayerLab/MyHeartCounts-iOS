//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GRDB
import Grove
import GroveFHIRContract
import GroveFoundation
@testable import GroveHealthKit
import GroveTesting
import HealthKit
import ModelsR4
@testable import MyHeartCounts
import OSLog
import Synchronization
import Testing

// The batch-export tests' shared fixtures intentionally live in one file.
// swiftlint:disable file_types_order

/// A standard that takes no deliveries, so a test resolves staging's HealthKit dependency.
actor BatchExportTestStandard: Standard, HealthKitConstraint {
    func handleNewSamples<Sample>(
        _ addedSamples: some Collection<Sample> & Sendable,
        ofType sampleType: SampleType<Sample>
    ) async throws -> HealthKitAnchorCommitAction? { nil }

    func handleDeletedObjects<Sample>(
        _ deletedObjects: some Collection<HKDeletedObject> & Sendable,
        ofType sampleType: SampleType<Sample>,
        deletedAfter: Date?
    ) async throws -> HealthKitAnchorCommitAction? { nil }
}


/// Counts the transactions a ledger's database commits or rolls back: each is one transaction of Grove's storage.
final class LedgerTransactionCounter: TransactionObserver, Sendable {
    private let count = Mutex(0)

    var transactions: Int {
        count.withLock { $0 }
    }

    func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool {
        false
    }

    func databaseDidChange(with event: DatabaseEvent) {}

    func databaseDidCommit(_ db: Database) {
        count.withLock { $0 += 1 }
    }

    func databaseDidRollback(_ db: Database) {
        count.withLock { $0 += 1 }
    }
}


extension FHIRExchangeLedger {
    /// The reservations the ledger holds, active and retraction ones alike.
    var reservationCount: Int {
        get throws {
            try entryKeys(prefixedBy: "event/").count
        }
    }

    /// A ledger in its own directory below `root`, bound to `binding` and fenced by the live preferences, as staging
    /// and the app are.
    static func liveFencedInDirectory(_ root: URL, binding: InMemoryDeviceBinding = InMemoryDeviceBinding()) -> FHIRExchangeLedger {
        FHIRExchangeLedger(
            location: .directory(root.appending(path: "FHIRExchangeLedger", directoryHint: .isDirectory)),
            deviceBinding: binding,
            fence: .live
        )
    }

    /// Opens the ledger and counts every transaction it runs from now on.
    func countingTransactions() throws -> LedgerTransactionCounter {
        let counter = LedgerTransactionCounter()
        try withDatabaseForTesting { db in
            db.add(transactionObserver: counter, extent: .databaseLifetime)
        }
        return counter
    }
}


extension HealthUploadStaging {
    /// The ledger this staging reserves in.
    var ledger: FHIRExchangeLedger {
        get throws {
            try #require(testing).ledger
        }
    }

    /// The identity this staging exports under.
    var stateStore: FHIRExchangeStateStore {
        get throws {
            try #require(testing).stateStore
        }
    }

    /// Staging attributed to the ledger harness's participant, with its HealthKit dependency resolved, and, when
    /// `ledger` is given, reserving in it.
    static func resolvedForTesting(
        persistence: Persistence = .inMemory,
        autoElideUploadsWhenInsertingDeletions: Bool = true,
        ledger: FHIRExchangeLedger? = nil
    ) async throws -> HealthUploadStaging {
        let staging = HealthUploadStaging.forTesting(
            persistence: persistence,
            autoElideUploadsWhenInsertingDeletions: autoElideUploadsWhenInsertingDeletions,
            subject: try LedgerHarness.subject
        )
        if let ledger {
            staging.testing?.ledger = ledger
        }
        await withDependencyResolution(standard: BatchExportTestStandard()) {
            staging
            HealthKit()
        }
        return staging
    }

    /// Removes every staged sample row, returning each row's decompressed FHIR JSON by sample.
    func drainStagedSamples() throws -> [UUID: Data] {
        var staged: [UUID: Data] = [:]
        while let chunk = try fetchNextDrainChunk(of: PendingSampleRecord.self, before: .distantFuture, limit: 10_000) {
            for row in chunk.rows {
                staged[row.sampleId] = try row.fhirJson.decompressed(using: Zstd.self)
            }
            try remove(chunk)
        }
        return staged
    }
}


/// The upload files a test staged, decompressed, in the order they were staged.
final class StagedUploadFiles: Sendable {
    private let files = Mutex<[Data]>([])

    var all: [Data] {
        files.withLock { $0 }
    }

    /// Stages `file` as the managed upload would: its bytes are kept, and the caller removes the file.
    func stage(_ file: URL) throws {
        let json = try Data(contentsOf: file).decompressed(using: Zstd.self)
        files.withLock { $0.append(json) }
    }
}


extension MyHeartCountsStandard.HealthObservationUploadDependencies {
    /// Uploads attributed to the ledger harness's participant: rows go to `staging`, and an upload file's HealthKit
    /// samples are exported as staging exports them and staged into `files`; a live delivery is accepted as
    /// `acceptsDelivery` decides.
    static func testing(
        staging: HealthUploadStaging,
        files: StagedUploadFiles = StagedUploadFiles(),
        acceptsDelivery: @escaping @Sendable () async throws -> Bool = { true }
    ) -> Self {
        testing(staging: staging, acceptsDelivery: acceptsDelivery) { file, _ in
            try files.stage(file)
        }
    }

    /// ``testing(staging:files:acceptsDelivery:)`` staging each upload file through `stageFile`.
    static func testing(
        staging: HealthUploadStaging,
        acceptsDelivery: @escaping @Sendable () async throws -> Bool = { true },
        stageFile: @escaping @Sendable (_ file: URL, _ accountDataGeneration: Int) async throws -> Void
    ) -> Self {
        Self(
            acceptsHealthKitDelivery: acceptsDelivery,
            subject: {
                try LedgerHarness.subject
            },
            staging: staging,
            healthKit: HealthKit(),
            exporter: { _, accountDataGeneration in
                try await staging.healthKitExporter(accountDataGeneration: accountDataGeneration)
            },
            stageFile: stageFile,
            logger: Logger(subsystem: "edu.stanford.MyHeartCounts.tests", category: "HealthObservationUpload")
        )
    }
}


extension HealthKitFHIRReservationReceipt {
    /// Runs the action Grove runs once the HealthKit anchor of the delivery is durable.
    func commitAnchor() async throws {
        let action = try #require(anchorCommitAction)
        await action()
    }
}


extension FHIRExchangeEventFacts {
    /// MHC's facts for one build, OS version and study revision.
    static func testing(build: String, operatingSystem: String, studyRevision: UInt) throws -> Self {
        Self(
            application: try ApplicationDevice(
                name: "My Heart Counts",
                bundleIdentifier: "edu.stanford.MyHeartCounts",
                version: "4.1",
                build: build
            ),
            host: try HostDevice(operatingSystemVersion: operatingSystem),
            study: Study(id: "7C1A5E0F-3B2D-4E6A-9F8B-0D1C2E3F4A5B", revision: studyRevision)
        )
    }
}


/// The event identifier a staged graph states as its `Bundle.identifier`.
func stagedEvent(_ json: Data) throws -> ExchangeEventIdentifier {
    let bundle = try JSONDecoder().decode(ModelsR4.Bundle.self, from: json)
    return try ExchangeEventIdentifier(BusinessIdentifier(try #require(bundle.identifier)))
}


/// The version every Device in a staged graph states: the converting application's build and the host's OS among them.
func stagedDeviceVersions(_ json: Data) throws -> Set<String> {
    let bundle = try JSONDecoder().decode(ModelsR4.Bundle.self, from: json)
    let devices = bundle.entry?.compactMap { $0.resource?.get(if: Device.self) } ?? []
    return Set(devices.flatMap { $0.version ?? [] }.compactMap { $0.value.value?.string })
}


/// `[`, the elements joined by `,`, and `]`, byte for byte.
func splicedJSONArray(_ elements: [Data]) -> Data {
    var array = Data("[".utf8)
    for (index, element) in elements.enumerated() {
        if index > 0 {
            array.append(contentsOf: Data(",".utf8))
        }
        array.append(element)
    }
    array.append(contentsOf: Data("]".utf8))
    return array
}


/// A heart-rate sample per index, distinct from every other.
func heartRateSample(_ index: Int) -> HKQuantitySample {
    let start = LedgerHarness.start.addingTimeInterval(TimeInterval(index) * 60)
    return HKQuantitySample(
        type: HKQuantityType(.heartRate),
        quantity: HKQuantity(unit: .count() / .minute(), doubleValue: Double(60 + index)),
        start: start,
        end: start.addingTimeInterval(30)
    )
}


/// Runs `body` with a fresh temporary directory, removed afterwards.
func withTemporaryRoot<R>(_ body: (URL) async throws -> R) async throws -> R {
    let root = URL.temporaryDirectory.appending(path: "HealthKitBatchExportTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: root)
    }
    return try await body(root)
}
