//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

// swiftlint:disable type_contents_order

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
    struct ID: Hashable, Codable, CustomStringConvertible, Sendable {
        private let value: String
        
        var description: String {
            value
        }
        
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
    
    enum State: Hashable, Sendable {
        case pending
        case completed
        case unavailable
    }
    
    struct CurrentStateContext: Sendable {
        /// When the participant first enrolled into the study.
        let enrollmentDate: Date
        /// When the participant activated the current local study enrollment within the on-device context of the My Heart Counts app.
        ///
        /// - Note: This is not necessarily equivalent to the ``enrollmentDate``.
        ///     For example, if the user deletes the app, re-installs it, and logs back in to their old account, the enrollment date would remain the same, but the activation date would get reset to when they completed the onboarding again as part of the reinstall.
        let studyActivationDate: Date
        /// Spezi
        let spezi: Spezi
        
        var daysSinceActivation: Int {
            Calendar.current.offsetInDays(from: studyActivationDate, to: .now)
        }
    }
    
    typealias CurrentState = @Sendable @MainActor (_ context: CurrentStateContext) -> State
    
    
    struct Content: Hashable {
        let symbol: SFSymbol
        let title: LocalizedStringResource
        let message: LocalizedStringResource
        /// Title of the button that actually performs the action
        let performActionButtonTitle: LocalizedStringResource
    }
    
    enum Action: Sendable {
        case closure(@Sendable @MainActor (Spezi) async throws -> Void)
        /// - Important: The sheet is responsible for dismissing itself!
        case sheet(@Sendable @MainActor () -> AnyView)
    }
    
    nonisolated let id: ID
    /// The action's condition.
    ///
    /// The action will only be prompted to the user if all condutions evaluate to true.
    private let currentState: CurrentState
    let content: Content
    let action: Action
    
    nonisolated private init(id: ID, currentState: @escaping CurrentState, content: Content, action: Action) {
        self.id = id
        self.currentState = currentState
        self.content = content
        self.action = action
    }
    
    nonisolated convenience init(
        id: ID,
        state: @escaping CurrentState,
        content: Content,
        handler: @escaping @Sendable @MainActor (Spezi) async throws -> Void
    ) {
        self.init(id: id, currentState: state, content: content, action: .closure(handler))
    }
    
    nonisolated convenience init(
        id: ID,
        state: @escaping CurrentState,
        content: Content,
        @ViewBuilder sheetContent: @escaping @Sendable @MainActor () -> some View
    ) {
        self.init(
            id: id,
            currentState: state,
            content: content,
            action: .sheet { AnyView(sheetContent()) }
        )
    }
    
    func state(context: CurrentStateContext) -> State {
        guard !FeatureFlags.isTakingDemoScreenshots else {
            return .unavailable
        }
        return currentState(context)
    }
}
