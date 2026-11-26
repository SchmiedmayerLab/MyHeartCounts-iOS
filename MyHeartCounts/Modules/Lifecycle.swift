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
import SwiftUI
import Synchronization


@Observable
final class Lifecycle: ServiceModule, EnvironmentAccessible, @unchecked Sendable {
    private let lock = Mutex<Void>(())
    private(set) var scenePhase: ScenePhase = .inactive {
        didSet {
            handleLifecycleChange(from: oldValue, to: scenePhase)
        }
    }
    
    // swiftlint:disable attributes
    @ObservationIgnored @Dependency(LocalNotifications.self) private var localNotifications
    // swiftlint:enable attributes
    
    func run() async {
        await TimedWalkingTest.endLiveActivity()
        nonisolated(unsafe) var continuation: CheckedContinuation<Void, Never>?
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation = $0 }
        } onCancel: {
            Task {
                await TimedWalkingTest.endLiveActivity()
            }
            _ = continuation
        }
    }
    
    func _set<T>(_ keyPath: KeyPath<Lifecycle, T>, to value: T) { // swiftlint:disable:this identifier_name
        guard let keyPath = keyPath as? ReferenceWritableKeyPath<Lifecycle, T> else {
            return
        }
        lock.withLock { _ in
            self[keyPath: keyPath] = value
        }
    }
    
    private func handleLifecycleChange(from oldValue: ScenePhase, to newValue: ScenePhase) {
        guard LocalPreferencesStore.standard[.enableAppLifecycleNotifications] else {
            return
        }
        Task {
            try? await localNotifications.send(
                title: "[dbg] lifecycle change",
                body: "\(oldValue.rawValue) → \(newValue.rawValue)"
            )
        }
    }
}


extension LocalPreferenceKeys {
    static let enableAppLifecycleNotifications = LocalPreferenceKey<Bool>("enableAppLifecycleNotifications", default: false)
}


extension ScenePhase: @retroactive RawRepresentable<String>, @retroactive CustomDebugStringConvertible {
    public var debugDescription: String {
        rawValue
    }
    
    public var rawValue: String {
        switch self {
        case .background:
            "background"
        case .inactive:
            "inactive"
        case .active:
            "active"
        @unknown default:
            "unknown"
        }
    }
    
    public init?(rawValue: String) {
        switch rawValue {
        case "background":
            self = .background
        case "inactive":
            self = .inactive
        case "active":
            self = .active
        default:
            return nil
        }
    }
}


// MARK: First activation

extension Lifecycle {
    /// Whether the app has been active at some point during this process' lifetime.
    @MainActor private static var hasBeenActive = false
    @MainActor private static var pendingActivationWork: [@MainActor () -> Void] = []

    /// Runs `work` once the app first becomes active, i.e., once someone actually opens it.
    ///
    /// Use this for launch-time work that only matters while the app is being used. A launch into the background
    /// (a background task, HealthKit background delivery) then leaves its short time budget to the work that woke the app up.
    /// The app doesn't know which kind of launch it is until the scene enters the foreground, so this is decided by waiting for that.
    ///
    /// If the app has already been active during this process' lifetime, `work` runs right away.
    /// Keep `work` short; start a `Task` for anything longer.
    @MainActor
    static func afterFirstActivation(_ work: @escaping @MainActor () -> Void) {
        if hasBeenActive {
            work()
        } else {
            pendingActivationWork.append(work)
        }
    }

    @MainActor
    fileprivate static func scenePhaseDidChange(to newValue: ScenePhase) {
        guard newValue == .active, !hasBeenActive else {
            return
        }
        hasBeenActive = true
        LaunchSignposts.signposter.emitEvent("First Activation")
        for work in exchange(&pendingActivationWork, with: []) {
            work()
        }
    }
}


// MARK: SwiftUI integration

extension Lifecycle {
    fileprivate struct ScenePhaseTrackingModifier: ViewModifier {
        @Environment(\.scenePhase)
        private var scenePhase

        @Environment(Lifecycle.self)
        private var lifecycle

        func body(content: Content) -> some View {
            content
                .onChange(of: scenePhase, initial: true) { _, newValue in
                    lifecycle._set(\.scenePhase, to: newValue)
                    Lifecycle.scenePhaseDidChange(to: newValue)
                }
        }
    }
}


extension View {
    func trackingScenePhase() -> some View {
        self.modifier(Lifecycle.ScenePhaseTrackingModifier())
    }
}
