//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

#if !os(Linux)

public import MHCStudyDefinition


extension StudyVariant: LaunchOptionDecodable, LaunchOptionEncodable {
    public func launchOptionArgs(for launchOption: LaunchOption<StudyVariant>) -> [String] {
        [launchOption.key, rawValue]
    }
}


extension LaunchOptions {
    /// Allows forcing the app to launch into a specific study variant. See `FeatureFlags.forcedStudyVariant` for more info.
    public static let studyVariant = LaunchOption<StudyVariant?>("--studyVariant", default: nil)
}

#endif
