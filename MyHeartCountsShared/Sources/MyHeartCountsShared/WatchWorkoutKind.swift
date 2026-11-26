//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

/// The type of workout the iPhone asks the watch to track, sent as the `InterDeviceUserInfoKey.watchWorkoutActivityKind` value.
///
/// The raw values are part of what the iPhone sends to the watch app. They match the raw values of
/// `GroveStudyDefinition/TimedWalkingTestConfiguration/Kind`, which the iPhone sent before this type existed.
/// Don't change them: the iPhone and the watch can run different versions of the app for a while.
public enum WatchWorkoutKind: UInt8, Hashable, Sendable {
    case walking = 0
    case running = 1
}
