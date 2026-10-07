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
import GroveFoundation
import GroveHealthKit
import GroveHealthKitFHIR
import MyHeartCountsShared
import OSLog


/// The one definition of a staged upload batch's wire format.
enum HealthUploadBatch {
    /// The deterministic JSON every upload path writes: sorted keys, unescaped slashes.
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private static let filenameDigestByteCount = 12

    /// The file name of a batch: its type prefix and a digest of its sorted identifiers, so the same batch is always
    /// written, and uploaded, under the same name.
    static func filename(
        typePrefix: String,
        identifiers: some Sequence<UUID>,
        fileExtension: String
    ) -> String {
        let canonicalIdentifiers = identifiers
            .map { $0.uuidString.lowercased() }
            .sorted()
            .joined(separator: "\n")
        let digest = SHA256.hash(data: Data(canonicalIdentifiers.utf8))
        let key = digest.prefix(filenameDigestByteCount).lowercaseHexString
        return "\(typePrefix)_\(key).\(fileExtension)"
    }

    /// Sorts, splices, compresses, and writes one batch, returning the file staged uploads take.
    ///
    /// Every path producing a batch goes through here, so their bytes and filenames cannot diverge. A graph's
    /// validated bytes are spliced in verbatim, never re-encoded.
    static func write(
        _ entries: consuming [PreparedHealthObservationFHIRPayload.Entry],
        typePrefix: String
    ) throws -> URL {
        var entries = consume entries
        entries.sort(by: precedes)
        let compressed = try jsonArray(entries) { try $0.json() }
            .compressed(using: Zstd.self)
        return try write(
            compressed,
            typePrefix: typePrefix,
            identifiers: entries.map(\.sourceID),
            fileExtension: "json.zstd"
        )
    }

    /// Writes already-serialized batch bytes under the digest-derived batch filename.
    static func write(
        _ payload: consuming Data,
        typePrefix: String,
        identifiers: some Sequence<UUID>,
        fileExtension: String
    ) throws -> URL {
        let url = URL.temporaryDirectory.appending(
            path: filename(
                typePrefix: typePrefix,
                identifiers: identifiers,
                fileExtension: fileExtension
            ),
            directoryHint: .notDirectory
        )
        try (consume payload).write(to: url, options: .atomic)
        return url
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

    /// The order entries are written in, so redelivery reproduces the same bytes.
    static func precedes(
        _ lhs: PreparedHealthObservationFHIRPayload.Entry,
        _ rhs: PreparedHealthObservationFHIRPayload.Entry
    ) -> Bool {
        let lhsID = lhs.sourceID.uuidString.lowercased()
        let rhsID = rhs.sourceID.uuidString.lowercased()
        if lhsID != rhsID {
            return lhsID < rhsID
        }
        return lhs.sourceTypeIdentifier < rhs.sourceTypeIdentifier
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

    nonisolated private static var drainChunkSize: Int? {
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
        let healthUploadStaging = await healthUploadStaging
        let managedFileUpload = await managedFileUpload
        let maximumChunksPerTable = allowance == .limited ? 1 : nil
        let didDrainSamples = try await drainPendingSamples(
            from: healthUploadStaging,
            to: managedFileUpload,
            before: processingCutoff,
            maximumChunks: maximumChunksPerTable
        )
        guard didDrainSamples else {
            return
        }
        let didDrainDeletions = try await Self.drainPendingDeletions(
            from: healthUploadStaging,
            before: processingCutoff,
            maximumChunks: maximumChunksPerTable
        ) { url in
            try await managedFileUpload.stage(url, category: .healthDeletions)
        }
        if didDrainDeletions {
            LocalPreferencesStore.standard[.lastStagedHealthUploadDrain] = .now
        }
    }
}


extension HealthUploadStagingUploader {
    /// Drains staged deletions chunk by chunk, each of one sample type.
    ///
    /// One exporter call retracts a chunk; `stage` takes its payload, the chunk is removed, and only then are
    /// the chunk's reservations released, so a crash anywhere before redelivers the chunk as an exact retry.
    nonisolated static func drainPendingDeletions(
        from healthUploadStaging: HealthUploadStaging,
        before processingCutoff: Date,
        maximumChunks: Int?,
        stage: (URL) async throws -> Void
    ) async throws -> Bool {
        var drainedChunks = 0
        while maximumChunks.map({ drainedChunks < $0 }) ?? true {
            try Task.checkCancellation()
            guard !ProcessInfo.processInfo.isLowPowerModeEnabled else {
                return false
            }
            guard let chunkSize = Self.drainChunkSize else {
                return false
            }
            guard let chunk = try healthUploadStaging.fetchNextDrainChunk(
                of: HealthUploadStaging.PendingDeletionRecord.self,
                before: processingCutoff,
                limit: chunkSize
            ) else {
                return true
            }
            guard !ProcessInfo.processInfo.isLowPowerModeEnabled else {
                return false
            }
            let rows = chunk.rows.sorted {
                $0.sampleId.uuidString.lowercased() < $1.sampleId.uuidString.lowercased()
            }
            let batch = try await healthUploadStaging.retractionBatch(for: rows)
            // A chunk without anything to retract stages nothing, but still releases what it reserved.
            if let payload = batch.payload {
                let url = try HealthUploadBatch.write(
                    try payload.compressed(using: Zstd.self),
                    typePrefix: chunk.sampleType,
                    identifiers: batch.identifiers,
                    fileExtension: "json.zstd"
                )
                defer {
                    try? FileManager.default.removeItem(at: url)
                }
                try Task.checkCancellation()
                try await stage(url)
            }
            try healthUploadStaging.remove(chunk)
            batch.receipt.completeAfterSourceAcknowledgement()
            drainedChunks += 1
        }
        return true
    }

    @concurrent
    private func drainPendingSamples(
        from healthUploadStaging: HealthUploadStaging,
        to managedFileUpload: ManagedFileUpload,
        before processingCutoff: Date,
        maximumChunks: Int?
    ) async throws -> Bool {
        var drainedChunks = 0
        while maximumChunks.map({ drainedChunks < $0 }) ?? true {
            try Task.checkCancellation()
            guard !ProcessInfo.processInfo.isLowPowerModeEnabled else {
                return false
            }
            guard let chunkSize = Self.drainChunkSize else {
                return false
            }
            guard let chunk = try healthUploadStaging.fetchNextDrainChunk(
                of: HealthUploadStaging.PendingSampleRecord.self,
                before: processingCutoff,
                limit: chunkSize
            ) else {
                return true
            }
            try Task.checkCancellation()
            guard !ProcessInfo.processInfo.isLowPowerModeEnabled else {
                return false
            }
            let rows = chunk.rows.sorted {
                $0.sampleId.uuidString.lowercased() < $1.sampleId.uuidString.lowercased()
            }
            let jsonArray = try rows.jsonArrayData()
            let compressed = try (consume jsonArray).compressed(using: Zstd.self)
            try Task.checkCancellation()
            let url = try HealthUploadBatch.write(
                compressed,
                typePrefix: chunk.sampleType,
                identifiers: rows.lazy.map(\.sampleId),
                fileExtension: "json.zstd"
            )
            defer {
                try? FileManager.default.removeItem(at: url)
            }
            try Task.checkCancellation()
            try await managedFileUpload.stage(url, category: .liveHealthUpload)
            try healthUploadStaging.remove(chunk)
            drainedChunks += 1
        }
        return true
    }
}


extension Collection where Element == HealthUploadStaging.PendingSampleRecord {
    /// Combines the records' decompressed FHIR JSON payloads into a single JSON array.
    func jsonArrayData() throws -> Data {
        try HealthUploadBatch.jsonArray(
            self,
            reservingCapacity: self.reduce(into: 2 + count) { $0 += $1.fhirJson.count * 6 } // ~6x expected zstd ratio
        ) { record in
            try record.fhirJson.decompressed(using: Zstd.self)
        }
    }
}


extension MHCBackgroundTasks.TaskIdentifier {
    static let stagedHealthUpload = Self("edu.stanford.MyHeartCounts.stagedHealthSamplesUpload")
}


extension LocalPreferenceKeys {
    /// The last time the staged health upload drain ran to completion.
    static let lastStagedHealthUploadDrain = LocalPreferenceKey<Date?>("lastStagedHealthUploadDrain")
}
