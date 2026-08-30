//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import Grove
import GroveFoundation
import GroveHealthKit
import GroveStudyDefinition
import MyHeartCountsShared
import Synchronization
import WatchConnectivity


/// A Module that runs on the iPhone and handles simple interactions with any connected Apple Watches.
@Observable
@MainActor
final class WatchConnection: NSObject, Module, EnvironmentAccessible, Sendable {
    // swiftlint:disable attributes
    @ObservationIgnored @Dependency(HealthKit.self) private var healthKit
    // swiftlint:enable attributes
    
    /// Indicates whether the user has an Apple Watch paired with their iPhone.
    ///
    /// - Note: This value being true might not necessarily mean that the Apple Watch is actually currently reachable and connected.
    private(set) var userHasWatch = false
    /// Indicates whether the current app's counterpart Apple Watch app is currently reachable and can receive/send messages.
    private(set) var isWatchAppReachable = false
    /// Indicates whether the current app's counterpart Apple Watch app is currently installed.
    private(set) var isWatchAppInstalled = false
    
    nonisolated(unsafe) private let wcSession: WCSession = .default
    
    func configure() {
        wcSession.delegate = self
        wcSession.activate()
    }
    
    func startWorkoutOnWatch(for test: TimedWalkingTestConfiguration) async throws {
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .walking
        configuration.locationType = .outdoor
        
        try await healthKit.startWatchApp(toHandle: configuration, timeout: .seconds(2.5))
        wcSession.send(userInfo: [
            .watchShouldEnableWorkout: true,
            .watchWorkoutActivityKind: test.kind.rawValue,
            .watchWorkoutDuration: test.duration.timeInterval,
            .watchWorkoutStartDate: Date.now
        ])
    }
    
    // periphery:ignore - API
    func stopWorkoutOnWatch() async throws {
        wcSession.send(userInfo: [.watchShouldEnableWorkout: false])
    }
}


extension WatchConnection: WCSessionDelegate {
    nonisolated private func updateStateRelatedProperties() {
        Task { @MainActor in
            let update = { (selfKeyPath: ReferenceWritableKeyPath<WatchConnection, Bool>, sessionKeyPath: KeyPath<WCSession, Bool>) in
                if self[keyPath: selfKeyPath] != self.wcSession[keyPath: sessionKeyPath] {
                    self[keyPath: selfKeyPath] = self.wcSession[keyPath: sessionKeyPath]
                }
            }
            update(\.userHasWatch, \.isPaired)
            update(\.isWatchAppInstalled, \.isWatchAppInstalled)
            update(\.isWatchAppReachable, \.isReachable)
        }
    }
    
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?) {
        Task { @MainActor in
            updateStateRelatedProperties()
        }
    }
    
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {
        // ...
    }
    
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // ...
    }
    
    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in
            updateStateRelatedProperties()
        }
    }
    
    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            updateStateRelatedProperties()
        }
    }
}


extension HealthKit {
    /// Attempts to launch the companion watchOS app, to handle a workout configuration.
    ///
    /// - parameter configuration: The workout configuration the companion app should handle
    /// - parameter timeout: How long the function should wait for the companion app to launch.
    func startWatchApp(toHandle configuration: HKWorkoutConfiguration, timeout: Duration) async throws {
        actor DidResolve {
            private var didResolve = false
            func resolve() -> Bool {
                guard !didResolve else {
                    return false
                }
                didResolve = true
                return true
            }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let didResolve = DidResolve()
            healthStore.startWatchApp(with: configuration) { @Sendable _, error in
                Task {
                    guard await didResolve.resolve() else {
                        return
                    }
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
            Task {
                try await Task.sleep(for: timeout)
                if await didResolve.resolve() {
                    continuation.resume(throwing: CancellationError())
                }
            }
        }
    }
}
