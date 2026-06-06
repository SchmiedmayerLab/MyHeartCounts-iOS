//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

// swiftlint:disable all

import Foundation
import Spezi
import SpeziHealthKit
import enum SwiftUI.ScenePhase


final class StatsUploader: Module {
    // swiftlint:disable attributes
    @Dependency(HealthKit.self) private var healthKit
    @Dependency(Lifecycle.self) private var lifecycle
    // swiftlint:enable attributes
    
    private var shouldUpdateStats: Bool {
        lifecycle.scenePhase == .active // || <didn't yet update today>
    }
    
    func configure() {
        Task(priority: .background) {
            if shouldUpdateStats {
                try await updateStats()
            }
        }
    }
    
    private func updateStats() async throws {
        // TODO
    }
}
