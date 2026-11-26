//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import OSLog


/// Signposts that mark the phases of an app launch, so that launches can be profiled in Instruments.
///
/// They show up in the Points of Interest track (e.g., in the App Launch template):
/// - "Launch": from `MyHeartCounts.init()` until `application(_:didFinishLaunchingWithOptions:)`,
///     which covers creating and configuring every module in the delegate's configuration;
/// - "First Activation": the app became active for the first time, i.e., someone opened it.
enum LaunchSignposts {
    static let signposter = OSSignposter(
        subsystem: Bundle.main.bundleIdentifier ?? "edu.stanford.MyHeartCounts",
        category: .pointsOfInterest
    )

    @MainActor private static var launchInterval: OSSignpostIntervalState?

    @MainActor
    static func beginLaunch() {
        launchInterval = signposter.beginInterval("Launch")
    }

    @MainActor
    static func endLaunch() {
        if let launchInterval = exchange(&launchInterval, with: nil) {
            signposter.endInterval("Launch", launchInterval)
        }
    }
}
