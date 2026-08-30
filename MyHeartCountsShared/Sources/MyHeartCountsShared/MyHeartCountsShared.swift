//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

#if canImport(WatchConnectivity)

public import WatchConnectivity


/// Key into a User Info dictionary transferred from the iPhone app to the Watch app.
public struct InterDeviceUserInfoKey: RawRepresentable, Hashable, Sendable {
    /// The key's raw value
    public let rawValue: String
    
    /// Creates a new key
    @inlinable
    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}


extension InterDeviceUserInfoKey {
    /// `Bool` flag indicating that the watch should start a workout
    public static let watchShouldEnableWorkout = Self(rawValue: "edu.stanford.MyHeartCounts.enableWatchWorkout")
    
    /// `UInt8` value specifying which type of workout the watch should track.
    ///
    /// The value here corresponds to a `GroveStudyDefinition/TimedWalkingTestConfiguration/Kind` raw value.
    public static let watchWorkoutActivityKind = Self(rawValue: "edu.stanford.MyHeartCounts.watchWorkoutActivityKind")
    
    /// `TimeInterval` value specifying the duration of the to-be-tracked workout, in seconds.
    public static let watchWorkoutDuration = Self(rawValue: "edu.stanford.MyHeartCounts.watchWorkoutDuration")
    
    /// `Date` value specifying the start date of the to-be-tracked workout.
    public static let watchWorkoutStartDate = Self(rawValue: "edu.stanford.MyHeartCounts.watchWorkoutStartDate")
}


extension WCSession {
    /// Sends the specified user info dictionary to the companion app.
    @inlinable
    public func send(userInfo: [InterDeviceUserInfoKey: Any]) {
        let userInfo: [String: Any] = .init(userInfo)
        self.transferUserInfo(userInfo)
    }
}

#endif
