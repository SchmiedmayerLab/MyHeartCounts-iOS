//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import Grove
import GroveStudyDefinition
import MyHeartCountsShared
import WatchConnectivity


/// A Module that runs on the Watch and handles simple interactions with its corresponding iPhone.
@Observable
@MainActor
final class PhoneConnection: NSObject, Module, WCSessionDelegate {
    @ObservationIgnored @Dependency(WorkoutManager.self) private var workoutManager // swiftlint:disable:this attributes
    
    @ObservationIgnored private let wcSession: WCSession = .default
    private(set) var userInfo: [InterDeviceUserInfoKey: Any] = [:]
    
    func configure() {
        wcSession.delegate = self
        wcSession.activate()
    }
    
    
    // MARK: WCSessionDelegate
    
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?) {
        // ...
    }
    
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        guard let userInfo: [InterDeviceUserInfoKey: Any] = .init(userInfo) else {
            return
        }
        // userInfo isn't Sendable (it is, but the compiler doesn't know this), so we end up with two separate branches with a Task each...
        if userInfo[.watchShouldEnableWorkout] as? Bool == true,
           let kindRawValue = userInfo[.watchWorkoutActivityKind] as? TimedWalkingTestConfiguration.Kind.RawValue,
           let duration = userInfo[.watchWorkoutDuration] as? TimeInterval,
           let startDate = userInfo[.watchWorkoutStartDate] as? Date,
           let kind = TimedWalkingTestConfiguration.Kind(rawValue: kindRawValue) {
            Task {
                try? await workoutManager.startWorkout(
                    for: .init(duration: .seconds(duration), kind: kind),
                    timeRange: startDate..<startDate.addingTimeInterval(duration)
                )
            }
        } else {
            Task {
                try? await workoutManager.stopWorkout()
            }
        }
    }
}
