//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GRDB
import HealthKit
import struct ModelsR4.FHIRPrimitive
import struct ModelsR4.Instant
import enum ModelsR4.ResourceProxy
import MyHeartCountsShared
import OSLog
import Spezi
import SpeziFoundation
import SpeziHealthKit
import UIKit


@Observable
@MainActor
final class HealthUploadStagingUploader: Spezi::Module, EnvironmentAccessible, Sendable {
    private enum ProcessingError: Error {
        case protectedDataUnavailable
    }

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
            try backgroundTasks.register(.processing(
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
        guard UIApplication.shared.isProtectedDataAvailable else {
            throw ProcessingError.protectedDataUnavailable
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
        let didDrainDeletions = try await drainPendingDeletions(
            from: healthUploadStaging,
            to: managedFileUpload,
            before: processingCutoff,
            maximumChunks: maximumChunksPerTable
        )
        if didDrainDeletions {
            LocalPreferencesStore.standard[.lastStagedHealthUploadDrain] = .now
        }
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
            guard await UIApplication.shared.isProtectedDataAvailable else {
                throw ProcessingError.protectedDataUnavailable
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
            let jsonArray = try chunk.rows.jsonArrayData()
            let compressed = try (consume jsonArray).compressed(using: Zstd.self)
            try Task.checkCancellation()
            let url = URL.temporaryDirectory.appending(
                path: "\(chunk.sampleType)_\(UUID().uuidString).json.zstd",
                directoryHint: .notDirectory
            )
            defer {
                try? FileManager.default.removeItem(at: url)
            }
            try (consume compressed).write(to: url)
            try Task.checkCancellation()
            try await managedFileUpload.stage(url, category: .liveHealthUpload)
            try healthUploadStaging.remove(chunk)
            drainedChunks += 1
        }
        return true
    }

    @concurrent
    private func drainPendingDeletions(
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
            guard await UIApplication.shared.isProtectedDataAvailable else {
                throw ProcessingError.protectedDataUnavailable
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
            let csvWriter = try CSVWriter(columns: ["sampleType", "sampleId", "timestamp"])
            for (index, deletion) in chunk.rows.enumerated() {
                if index.isMultiple(of: 256) {
                    try Task.checkCancellation()
                }
                try csvWriter.appendRow(fields: [
                    deletion.sampleType, deletion.sampleId, deletion.timestamp
                ] as [any CSVWriter.FieldValue])
            }
            let csvData = csvWriter.data()
            let url = URL.temporaryDirectory.appending(
                path: "\(chunk.sampleType)_\(UUID().uuidString).csv.zstd",
                directoryHint: .notDirectory
            )
            defer {
                try? FileManager.default.removeItem(at: url)
            }
            try (consume csvData).compressed(using: Zstd.self).write(to: url)
            try Task.checkCancellation()
            try await managedFileUpload.stage(url, category: .healthDeletions)
            try healthUploadStaging.remove(chunk)
            drainedChunks += 1
        }
        return true
    }
}


extension Collection where Element == HealthUploadStaging.PendingSampleRecord {
    /// Combines the records' decompressed FHIR JSON payloads into a single JSON array.
    func jsonArrayData() throws -> Data {
        var json = Data()
        json.reserveCapacity(self.reduce(into: 2 + count) { $0 += $1.fhirJson.count * 6 }) // ~6x expected zstd ratio
        json.append(UInt8(ascii: "["))
        var isFirst = true
        for record in self {
            if !isFirst {
                json.append(UInt8(ascii: ","))
            }
            isFirst = false
            json.append(try record.fhirJson.decompressed(using: Zstd.self))
        }
        json.append(UInt8(ascii: "]"))
        return json
    }
}


extension MHCBackgroundTasks.TaskIdentifier {
    static let stagedHealthUpload = Self("edu.stanford.MyHeartCounts.stagedHealthSamplesUpload")
}


extension LocalPreferenceKeys {
    /// The last time the staged health upload drain ran to completion.
    static let lastStagedHealthUploadDrain = LocalPreferenceKey<Date?>("lastStagedHealthUploadDrain")
}
