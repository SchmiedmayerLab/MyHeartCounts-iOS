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


@Observable
final class HealthUploadStagingUploader: Spezi::Module, EnvironmentAccessible, @unchecked Sendable {
    /// The number of whole days all data will be retained locally, before it is shared with the backend.
    ///
    /// E.g., if this value is `2`, any data collected on monday will be processed on thursday at the earliest.
    /// (To ensure that there are 2 whole days inbetween.)
    private static let dataRetentionOffsetInDays = 3
    
    // swiftlint:disable attributes
    @ObservationIgnored @Application(\.logger) private var logger
    @ObservationIgnored @Dependency(HealthUploadStaging.self) private var healthUploadStaging
    @ObservationIgnored @Dependency(MHCBackgroundTasks.self) private var backgroundTasks
    @ObservationIgnored @Dependency(ManagedFileUpload.self) private var managedFileUpload
    // swiftlint:enable attributes
    
    func configure() {
        do {
            try backgroundTasks.register(.processing(
                id: .stagedHealthUpload,
                nextTriggerDate: .absolute(.now.addingTimeInterval(TimeConstants.hour * 6)),
                options: [.requiresNetworkConnectivity]
            ) {
                // QUESTION is it sufficient to have just the background task, or should we also call `process()` directly from configure?
                try await self.process()
            })
        } catch {
            logger.error("Failed to register \(MHCBackgroundTasks.TaskIdentifier.stagedHealthUpload) background task: \(error)")
        }
    }
    
    
    func process() async throws {
        let cal = Calendar.current
        guard let processingCutoff = cal
            .date(byAdding: .day, value: -Self.dataRetentionOffsetInDays, to: .now)
            .flatMap({ cal.startOfDay(for: $0) }) else {
            // should be unreachable
            return
        }
        let drainData = try healthUploadStaging.drainData(in: ..<processingCutoff)
        try await withThrowingDiscardingTaskGroup { taskGroup in // swiftlint:disable:this closure_body_length
            for batch in drainData.samples {
                taskGroup.addTask {
                    let jsonArray = try batch.rows.jsonArray()
                    let data = Data(jsonArray.utf8)
                    let compressed = try (consume data).compressed(using: Zstd.self)
                    let url = URL.temporaryDirectory.appending(
                        path: "\(batch.sampleType)_\(UUID().uuidString).json.zstd",
                        directoryHint: .notDirectory
                    )
                    try (consume compressed).write(to: url)
                    Swift::Task {
                        try await self.managedFileUpload.upload(url, category: .liveHealthUpload)
                    }
                    self.deleteDrainBatch(batch)
                }
            }
            // QUESTION have one CSV per samlpe type, or put them all into a single file?
            for batch in drainData.deletions {
                taskGroup.addTask {
                    let csvWriter = try CSVWriter(columns: ["sampleType", "sampleId", "timestamp"])
                    for deletion in batch.rows {
                        try csvWriter.appendRow(fields: [
                            deletion.sampleType, deletion.sampleId, deletion.timestamp
                        ] as [any CSVWriter.FieldValue])
                    }
                    let csvData = csvWriter.data()
                    let url = URL.temporaryDirectory.appending(
                        path: "HealthObservationDeletions_\(batch.sampleType)_\(UUID().uuidString).csv.zstd",
                        directoryHint: .notDirectory
                    )
                    try (consume csvData).compressed(using: Zstd.self).write(to: url)
                    Swift::Task {
                        try await self.managedFileUpload.upload(url, category: .healthDeletions)
                    }
                    self.deleteDrainBatch(batch)
                }
            }
        }
    }
    
    private func deleteDrainBatch<R>(_ batch: HealthUploadStaging.DrainBatch<R>) {
        do {
            try healthUploadStaging.remove(batch)
        } catch {
            self.logger.error("Failed to delete '\(R.databaseTableName)' drain batch: \(error)")
        }
    }
}


extension Collection where Element == HealthUploadStaging.PendingSampleRecord {
    func jsonArray() throws -> String {
        var json = "["
        json.append(contentsOf: try self.lazy
            .map {
                String(decoding: try $0.fhirJson.decompressed(using: Zstd.self), as: UTF8.self)
            }
            .joined(separator: ",") as JoinedSequence)
        json.append("]")
        return json
    }
}


extension MHCBackgroundTasks.TaskIdentifier {
    static let stagedHealthUpload = Self("edu.stanford.MyHeartCounts.stagedHealthSamplesUpload")
}
