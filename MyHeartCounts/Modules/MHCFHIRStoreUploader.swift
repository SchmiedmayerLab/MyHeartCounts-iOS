//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

// swiftlint:disable all

import Dispatch
import Foundation
import HealthKit
import struct ModelsR4.FHIRPrimitive
import struct ModelsR4.Instant
import enum ModelsR4.ResourceProxy
import Spezi
import Observation
import SpeziHealthKit
import MyHeartCountsShared
import SpeziFoundation
import OSLog


extension MHCBackgroundTasks.TaskIdentifier {
    static let fhirStoreUpload = Self("edu.stanford.MyHeartCounts.FHIRStoreUpload")
}


//@Observable
final class MHCFHIRStoreUploader: Spezi::Module, EnvironmentAccessible, @unchecked Sendable {
    /// The number of whole days all data will be retained locally, before it is shared with the backend.
    ///
    /// E.g., if this value is `2`, any data collected on monday will be processed on thursday at the earliest.
    /// (To ensure that there are 2 whole days inbetween.)
    private static let dataRetentionOffsetInDays = 2
    
    @Application(\.logger) private var logger
    
    @Dependency(MHCFHIRStore.self) private var fhirStore
    @Dependency(MHCBackgroundTasks.self) private var backgroundTasks
    @Dependency(ManagedFileUpload.self) private var managedFileUpload
    
    func configure() {
        do {
            try backgroundTasks.register(.processing(
                id: .fhirStoreUpload,
                nextTriggerDate: .absolute(.now.addingTimeInterval(TimeConstants.hour * 6)),
                options: [.requiresNetworkConnectivity]
            ) {
//                try await self.process() // TODO
            })
        } catch {
            logger.error("Failed to register \(MHCBackgroundTasks.TaskIdentifier.fhirStoreUpload) background task: \(error)")
        }
    }
    
    
    func process() async throws {
        let cal = Calendar.current
        guard let processingCutoff = cal.date(byAdding: .day, value: -Self.dataRetentionOffsetInDays, to: .now)
            .flatMap({ cal.startOfDay(for: $0) }) else {
            // should be unreachable
            return
        }
        return; // TODO
        let drainData = try fhirStore.drainData(in: ..<(.now))
        try await withThrowingDiscardingTaskGroup { taskGroup in
            for batch in drainData.samples {
                taskGroup.addTask {
                    // TODO write a unit test to check that this JSON can be properly decoded into an `[R4.ResourceProxy]`!!
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
                }
            }
            // TODO have one CSV per samlpe type, or put them all into a single file?
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
                    try csvData.write(to: url)
                    Swift::Task {
                        try await self.managedFileUpload.upload(url, category: .healthDeletions)
                    }
                }
            }
        }
    }
}


extension Collection where Element == MHCFHIRStore.PendingSampleRecord {
    func jsonArray() throws -> String {
        var json = "["
        //json.append(contentsOf: self.lazy.map(\.fhirJson).joined(separator: ",") as JoinedSequence)
//        for record in self {
//            let fhirJson = try record.fhirJson.decompressed(using: Zstd.self)
//        }
        json.append(contentsOf: try self.lazy
            .map {
                String(decoding: try $0.fhirJson.decompressed(using: Zstd.self), as: UTF8.self)
            }
            .joined(separator: ",") as JoinedSequence
        )
        json.append("]")
        return json
    }
}
