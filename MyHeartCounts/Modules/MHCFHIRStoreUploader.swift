//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

// swiftlint:disable all

import AsyncAlgorithms
import Dispatch
import Foundation
import HealthKit
import struct ModelsR4.FHIRPrimitive
import struct ModelsR4.Instant
import SQLite
import Spezi
import Observation
import SpeziHealthKit
import MyHeartCountsShared
import SpeziFoundation


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
    
    @Dependency(MHCFHIRStore.self) private var fhirStore
    @Dependency(MHCBackgroundTasks.self) private var backgroundTasks
    
    func configure() {
        do {
            try backgroundTasks.register(.processing(
                id: .fhirStoreUpload,
                nextTriggerDate: .absolute(.now.addingTimeInterval(TimeConstants.hour * 6)),
                options: [.requiresNetworkConnectivity]
            ) {
                try await self.process()
            })
        } catch {
            // TODO
        }
    }
    
    
    private func process() async throws {
        let cal = Calendar.current
        guard let processingCutoff = cal.date(byAdding: .day, value: -Self.dataRetentionOffsetInDays, to: .now)
            .flatMap({ cal.startOfDay(for: $0) }) else {
            // should be unreachable
            return
        }
    }
}
