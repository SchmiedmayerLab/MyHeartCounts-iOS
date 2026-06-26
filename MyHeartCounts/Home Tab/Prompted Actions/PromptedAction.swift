//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import MyHeartCountsShared
import SFSafeSymbols
@_spi(APISupport)
import Spezi
import SpeziHealthKit
import SpeziSensorKit


extension HomeTab {
    @Observable
    @MainActor
    final class PromptedAction: nonisolated Identifiable, Sendable {
        typealias Handler = @Sendable @MainActor (Spezi) async throws -> Void
        
        struct ID: Hashable, Codable, Sendable {
            private let value: String
            
            init(_ value: String) {
                self.value = value
            }
            
            init(from decoder: any Decoder) throws {
                let container = try decoder.singleValueContainer()
                self.value = try container.decode(String.self)
            }
            
            func encode(to encoder: any Encoder) throws {
                var container = encoder.singleValueContainer()
                try container.encode(self.value)
            }
        }
        
        enum Condition {
            /// A condition that evaluates to true, if the number of days that have passed since the study enrollment falls within the specified range.
            case daysSinceEnrollment(ClosedRange<Int>)
            /// A condition that uses a custom closure.
            case custom(@MainActor @Sendable (Spezi) -> Bool)
        }
        
        struct Content: Hashable {
            let symbol: SFSymbol
            let title: LocalizedStringResource
            let message: LocalizedStringResource
        }
        
        nonisolated let id: ID
        /// The action's condition.
        ///
        /// The action will only be prompted to the user if all condutions evaluate to true.
        let conditions: [Condition]
        let content: Content
        private let handler: Handler
        // intended for observing when the action was performed, and the UI needs to be updated.
        @MainActor private(set) var lastResult: Result<Void, any Error>?
        
        nonisolated init(id: ID, conditions: [Condition], content: Content, handler: @escaping Handler) {
            self.id = id
            self.conditions = conditions
            self.content = content
            self.handler = handler
        }
        
        func callAsFunction(_ spezi: Spezi) async throws {
            lastResult = await Result {
                try await handler(spezi)
            }
            try lastResult!.get() // swiftlint:disable:this force_unwrapping
        }
    }
}


extension HomeTab.PromptedAction.ID {
    static let sensorKit = Self("edu.stanford.MyHeartCounts.HomeTabAction.EnableSensorKit")
    static let clinicalRecords = Self("edu.stanford.MyHeartCounts.HomeTabAction.EnableClinicalRecords")
}


extension HomeTab.PromptedAction {
    static let allActions: [HomeTab.PromptedAction] = [.enableSensorKit]
    
    static let enableSensorKit = HomeTab.PromptedAction(
        id: .sensorKit,
        conditions: [
            .daysSinceEnrollment(0...21),
            .custom { _ in
                   SensorKit.isAvailable
                && !FeatureFlags.isTakingDemoScreenshots
                && SensorKit.mhcSensors.contains { $0.authorizationStatus == .notDetermined }
            }
        ],
        content: .init(
            symbol: .waveformPathEcgRectangle,
            title: "Enable SensorKit",
            message: "ENABLE_SENSORKIT_SUBTITLE"
        )
    ) { spezi in
        guard let sensorKit = spezi.module(SensorKit.self) else {
            return
        }
        let result = try await sensorKit.requestAccess(to: SensorKit.mhcSensors)
        for sensor in result.authorized {
            try? await sensor.startRecording()
        }
    }
    
    static let enableClinicalRecords = HomeTab.PromptedAction(
        id: .clinicalRecords,
        conditions: [
            .daysSinceEnrollment(0...21),
            .custom { spezi in
                spezi.module(ClinicalRecordPermissions.self)?.authorizationState == .cancelled
            }
        ],
        content: .init(
            symbol: HealthRecords.symbol,
            title: "Enable Clinical Records",
            message: "HEALTH_RECORDS_NUDGE_SUBTITLE"
        )
    ) { spezi in
        try await spezi.module(ClinicalRecordPermissions.self)?.askForAuthorization(askAgainIfCancelledPreviously: true)
    }
}
