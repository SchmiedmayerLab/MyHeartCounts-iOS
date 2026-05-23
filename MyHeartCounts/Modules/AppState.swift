//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Observation
import Spezi


@Observable
@MainActor
final class AppState: Module, EnvironmentAccessible, Sendable {
    /// Indicates that the user is currently in the process of being logged out.
    @MainActor private(set) var isLoggingOut = false
    
    
    @MainActor
    func setIsLoggingOut(_ newValue: Bool) {
        isLoggingOut = newValue
    }
}
