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
    /// An action that is presented to the user at the top of the ``HomeTab``.
    ///
    /// - Note: All actions are automatically considered disabled when MHC's automated screenshot flow is running.
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
            self.conditions = conditions + [.custom { _ in !FeatureFlags.isTakingDemoScreenshots }]
            self.content = content
            self.handler = handler
        }
        
        func callAsFunction(_ spezi: Spezi) async throws {
            lastResult = await Result {
                try await handler(spezi)
            }
            return try lastResult!.get() // swiftlint:disable:this force_unwrapping return_value_from_void_function
        }
    }
}
