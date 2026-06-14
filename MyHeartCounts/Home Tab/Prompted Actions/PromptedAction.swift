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
import SwiftUI


/// An action that is presented to the user at the top of the ``HomeTab``.
///
/// - Note: All actions are automatically considered disabled when MHC's automated screenshot flow is running.
@Observable
@MainActor
final class PromptedAction: nonisolated Identifiable, Sendable {
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
        /// Title of the button that actually performs the action
        let performActionButtonTitle: LocalizedStringResource
    }
    
    enum Action: Sendable {
        case closure(@Sendable @MainActor (Spezi) async throws -> Void)
        case sheet(@Sendable @MainActor (_ onCompletion: @escaping @Sendable @MainActor (Result<Void, any Error>) -> Void) -> AnyView)
    }
    
    nonisolated let id: ID
    /// The action's condition.
    ///
    /// The action will only be prompted to the user if all condutions evaluate to true.
    let conditions: [Condition]
    let content: Content
    let action: Action
    // intended for observing when the action was performed, and the UI needs to be updated.
    @MainActor private(set) var lastResult: Result<Void, any Error>?
    
    nonisolated private init(id: ID, conditions: [Condition], content: Content, action: Action) {
        self.id = id
        self.conditions = conditions + [.custom { _ in !FeatureFlags.isTakingDemoScreenshots }]
        self.content = content
        self.action = action
    }
    
    nonisolated convenience init(
        id: ID,
        enabledWhen conditions: [Condition],
        content: Content,
        handler: @escaping @Sendable @MainActor (Spezi) async throws -> Void
    ) {
        self.init(id: id, conditions: conditions, content: content, action: .closure(handler))
    }
    
    nonisolated convenience init(
        id: ID,
        enabledWhen conditions: [Condition],
        content: Content,
        @ViewBuilder sheetContent: @escaping @Sendable @MainActor (
            _ onCompletion: @escaping @Sendable @MainActor (Result<Void, any Error>) -> Void
        ) -> some View
    ) {
        self.init(
            id: id,
            conditions: conditions,
            content: content,
            action: .sheet { onCompletion in
                AnyView(sheetContent(onCompletion))
            }
        )
    }
    
    func _updateLastResult(_ result: Result<Void, any Error>) { // swiftlint:disable:this identifier_name
        lastResult = result
    }
}
