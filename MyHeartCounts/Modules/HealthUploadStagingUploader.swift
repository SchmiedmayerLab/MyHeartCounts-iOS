//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import CryptoKit
import Foundation
import GRDB
import Grove
import GroveFHIRContract
import GroveFoundation
import GroveHealthKit
import GroveHealthKitFHIR
import MyHeartCountsShared
import OSLog


/// The one definition of a staged upload batch's wire format.
enum HealthUploadBatch {
    /// How a packed Bundle is finished; the production behaviour is ``packBundle(_:packedAt:)``.
    typealias MakeBundle = @Sendable (ExchangeBundlePacker, Date) throws(ExchangeGraphError) -> ExchangeGraph

    enum PackingError: Error {
        /// Records fresh from the exporter can't travel in a Bundle.
        case unpackableRecords(count: Int)
    }

    /// The deterministic JSON of a refused deletion's object, whose bytes name its file: sorted keys, unescaped slashes.
    ///
    /// No other upload passes through it: Grove writes the JSON of every Bundle and record, and legacy arrays and a row's
    /// `unreadable_` object are its stored bytes.
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private static let filenameDigestByteCount = 12

    /// What file names state of `data`: 24 lowercase hex characters of its SHA-256.
    static func digest(of data: Data) -> String {
        SHA256.hash(data: data).prefix(filenameDigestByteCount).lowercaseHexString
    }

    /// The file name of a batch: its type prefix and a digest of the sorted fullUrls of its Provenances, so the same
    /// records are always written, and uploaded, under the same name.
    ///
    /// A Provenance fullUrl is keyed, so the name confirms nothing to someone who knows a sample's HealthKit UUID.
    static func filename(
        typePrefix: String,
        provenanceFullURLs: some Sequence<String>,
        fileExtension: String
    ) -> String {
        let canonicalFullURLs = provenanceFullURLs.sorted().joined(separator: "\n")
        return "\(typePrefix)_\(digest(of: Data(canonicalFullURLs.utf8))).\(fileExtension)"
    }

    /// The production ``MakeBundle``.
    static func packBundle(_ packer: ExchangeBundlePacker, packedAt: Date) throws(ExchangeGraphError) -> ExchangeGraph {
        try packer.bundle(packedAt: packedAt)
    }

    /// Compresses and writes one Bundle under its H17 name, returning the file staged uploads take.
    static func write(_ bundle: ExchangeGraph, typePrefix: String) throws -> URL {
        try write(
            try bundle.json.compressed(using: Zstd.self),
            filename: filename(typePrefix: typePrefix, provenanceFullURLs: bundle.provenanceFullURLs, fileExtension: "json.zstd")
        )
    }

    /// Writes already-serialized batch bytes under `filename`.
    static func write(_ payload: consuming Data, filename: String) throws -> URL {
        let url = URL.temporaryDirectory.appending(path: filename, directoryHint: .notDirectory)
        try (consume payload).write(to: url, options: .atomic)
        return url
    }

    /// Packs records fresh from the exporter and hands each Bundle's file to `stage`: one Bundle, unless the batch is past
    /// the packer's caps.
    ///
    /// - throws: ``PackingError/unpackableRecords(count:)`` when a record can't travel even alone; the batch then stays
    ///     unacknowledged.
    static func stage(
        _ records: [ExchangeRecord],
        sampleType: String,
        packedAt: Date,
        stage: (URL) async throws -> Void
    ) async throws {
        guard !records.isEmpty else {
            return
        }
        let packed = HealthUploadStagingUploader.packChunk(
            records.map { (rowID: UUID(), record: $0) },
            kind: .active,
            packedAt: packedAt
        )
        HealthUploadIntegrityEvent.report(packed.tally, sampleType: sampleType, to: HealthUploadIntegrityEvent.log)
        guard packed.failedAlone.isEmpty, packed.otherSubject.isEmpty else {
            throw PackingError.unpackableRecords(count: packed.failedAlone.count + packed.otherSubject.count)
        }
        for bundle in packed.bundles {
            let url = try write(bundle, typePrefix: sampleType)
            defer {
                try? FileManager.default.removeItem(at: url)
            }
            try await stage(url)
        }
    }

    /// One JSON array of `elements`, each spliced in verbatim as the bytes `json` gives for it.
    static func jsonArray<Element>(
        _ elements: some Sequence<Element>,
        reservingCapacity capacity: Int = 0,
        json: (Element) throws -> Data
    ) rethrows -> Data {
        var array = Data()
        array.reserveCapacity(capacity)
        array.append(UInt8(ascii: "["))
        var isFirst = true
        for element in elements {
            if !isFirst {
                array.append(UInt8(ascii: ","))
            }
            isFirst = false
            array.append(try json(element))
        }
        array.append(UInt8(ascii: "]"))
        return array
    }
}


@Observable
@MainActor
final class HealthUploadStagingUploader: Grove::Module, EnvironmentAccessible, Sendable {
    private struct ActiveDrain: Sendable {
        let task: Task<Void, any Error>
        let allowance: DeviceBattery.WorkAllowance
    }

    /// The number of whole days all data will be retained locally, before it is shared with the backend.
    ///
    /// E.g., if this value is `2`, any data collected on monday will be processed on thursday at the earliest.
    /// (To ensure that there are 2 whole days inbetween.)
    nonisolated private static let dataRetentionOffsetInDays = 3

    nonisolated static var drainChunkSize: Int? {
        let minimumChunkSize = 1000
        let maximumChunkSize = 10_000
        let bytesPerRecord = 10_000
        let minimumAvailableMemory = 64 * 1024 * 1024
        let availableMemory = os_proc_available_memory()

        #if targetEnvironment(simulator)
        if availableMemory == 0 {
            return 2000
        }
        #endif

        // Below 64 MiB, a useful batch leaves too little headroom for the rest of the app.
        guard availableMemory >= minimumAvailableMemory else {
            return nil
        }
        let calculatedChunkSize = availableMemory / 4 / bytesPerRecord
        guard calculatedChunkSize >= minimumChunkSize else {
            return nil
        }
        return min(maximumChunkSize, calculatedChunkSize)
    }

    // swiftlint:disable attributes
    @ObservationIgnored @Application(\.logger) private var logger
    @ObservationIgnored @Dependency(HealthUploadStaging.self) private var healthUploadStaging
    @ObservationIgnored @Dependency(FirebaseConfiguration.self) private var firebaseConfiguration
    @ObservationIgnored @Dependency(MHCBackgroundTasks.self) private var backgroundTasks
    @ObservationIgnored @Dependency(ManagedFileUpload.self) private var managedFileUpload
    @ObservationIgnored private var activeDrain: ActiveDrain?
    // swiftlint:enable attributes
    
    func configure() {
        do {
            // A health-research task rather than a plain processing task: same conditions, but iOS grants it the
            // longer execution window that draining and re-compressing a multi-day backlog can actually use.
            // The default data-protection requirement (first unlock) matches the staging database, so overnight
            // charging — the obvious window for a task that needs external power — still qualifies even while locked.
            try backgroundTasks.register(.healthResearch(
                id: .stagedHealthUpload,
                nextTriggerDate: .after(TimeConstants.hour * 6),
                options: [.requiresExternalPower, .requiresNetworkConnectivity]
            ) {
                try await self.process(.full)
            })
        } catch {
            logger.error("Failed to register \(MHCBackgroundTasks.TaskIdentifier.stagedHealthUpload) background task: \(error)")
        }
        Task(priority: .background) {
            let allowance = DeviceBattery.workAllowance(
                lastRun: LocalPreferencesStore.standard[.lastStagedHealthUploadDrain],
                staleness: TimeConstants.day
            )
            guard allowance != .none else {
                return
            }
            do {
                try await process(allowance)
            } catch is CancellationError {} catch {
                logger.error("Error processing staged health uploads: \(error)")
            }
        }
    }
    
    
    /// Cancels the current drain and waits for its local work to stop.
    @MainActor
    func cancelAndWaitForQuiescence() async {
        guard let activeDrain else {
            return
        }
        activeDrain.task.cancel()
        _ = await activeDrain.task.result
        if self.activeDrain?.task == activeDrain.task {
            self.activeDrain = nil
        }
    }

    @MainActor
    func process(_ allowance: DeviceBattery.WorkAllowance = .full) async throws {
        guard allowance != .none else {
            return
        }
        guard !LocalPreferencesStore.standard[.pendingAccountDataCleanupRequired] else {
            return
        }
        while true {
            let activeDrain: ActiveDrain
            if let existingDrain = self.activeDrain {
                activeDrain = existingDrain
            } else {
                let task = Task { @concurrent in
                    try await self._process(allowance)
                }
                activeDrain = ActiveDrain(task: task, allowance: allowance)
                self.activeDrain = activeDrain
            }
            defer {
                if self.activeDrain?.task == activeDrain.task {
                    self.activeDrain = nil
                }
            }
            try await withTaskCancellationHandler {
                try await activeDrain.task.value
            } onCancel: {
                activeDrain.task.cancel()
            }
            if allowance == .full && activeDrain.allowance == .limited {
                continue
            }
            return
        }
    }
    
    @concurrent
    private func _process(_ allowance: DeviceBattery.WorkAllowance) async throws {
        try Task.checkCancellation()
        let cal = Calendar.current
        let processingCutoff: Date
        if Self.dataRetentionOffsetInDays < 1 {
            processingCutoff = cal.startOfNextDay(for: .now)
        } else {
            guard let cutoff = cal
                .date(byAdding: .day, value: -Self.dataRetentionOffsetInDays, to: .now)
                .flatMap({ cal.startOfDay(for: $0) }) else {
                return
            }
            processingCutoff = cutoff
        }
        await logger.notice("processingCutoff: \(processingCutoff)")
        // Read once, for both drains: a row is drained under this subject, never one inferred from the row.
        guard let subject = try? await firebaseConfiguration.fhirExchangeSubject else {
            await logger.notice("Not draining staged health uploads while no account is signed in")
            return
        }
        let healthUploadStaging = await healthUploadStaging
        let managedFileUpload = await managedFileUpload
        let didDrain = try await Self.drainStagedUploads(
            from: healthUploadStaging,
            before: processingCutoff,
            maximumChunks: allowance == .limited ? 1 : nil,
            subject: subject
        ) { url, category in
            try await managedFileUpload.stage(url, category: category)
        }
        if didDrain {
            LocalPreferencesStore.standard[.lastStagedHealthUploadDrain] = .now
        }
    }
}


extension HealthUploadStagingUploader {
    /// Drains staged samples, then staged deletions, handing each file to `stage` with the category it uploads under.
    ///
    /// A sample drain that stopped early, or threw, leaves the deletions for the next drain.
    ///
    /// - parameter subject: The signed-in subject, which both drains take.
    /// - parameter makeBundle: How a packed Bundle is finished.
    /// - parameter chunkSize: How many rows the next chunk may take, or `nil` while memory is too low to take one.
    /// - parameter integrityEvents: Takes each chunk's integrity events, once the chunk is removed.
    /// - returns: Whether both drains ran to completion.
    @concurrent
    static func drainStagedUploads(
        from healthUploadStaging: HealthUploadStaging,
        before processingCutoff: Date,
        maximumChunks: Int?,
        subject: FHIRExchangeSubject,
        makeBundle: HealthUploadBatch.MakeBundle = HealthUploadBatch.packBundle,
        chunkSize: @Sendable () -> Int? = { HealthUploadStagingUploader.drainChunkSize },
        integrityEvents: @Sendable (HealthUploadIntegrityEvent) -> Void = HealthUploadIntegrityEvent.log,
        stage: @Sendable (URL, ManagedFileUpload.Category) async throws -> Void
    ) async throws -> Bool {
        let didDrainSamples = try await drainPendingSamples(
            from: healthUploadStaging,
            before: processingCutoff,
            maximumChunks: maximumChunks,
            subject: subject,
            stage: { url in
                try await stage(url, .liveHealthUpload)
            },
            stageUnreadable: { url in
                try await stage(url, .unreadableHealthUpload)
            },
            makeBundle: makeBundle,
            chunkSize: chunkSize,
            integrityEvents: integrityEvents
        )
        guard didDrainSamples else {
            return false
        }
        return try await drainPendingDeletions(
            from: healthUploadStaging,
            before: processingCutoff,
            maximumChunks: maximumChunks,
            subject: subject,
            stage: { url in
                try await stage(url, .healthDeletions)
            },
            stageUnreadable: { url in
                try await stage(url, .unreadableHealthUpload)
            },
            makeBundle: makeBundle,
            chunkSize: chunkSize,
            integrityEvents: integrityEvents
        )
    }
}


extension MHCBackgroundTasks.TaskIdentifier {
    static let stagedHealthUpload = Self("edu.stanford.MyHeartCounts.stagedHealthSamplesUpload")
}


extension LocalPreferenceKeys {
    /// The last time the staged health upload drain ran to completion.
    static let lastStagedHealthUploadDrain = LocalPreferenceKey<Date?>("lastStagedHealthUploadDrain")
}
