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
    /// Selects the study variant for a fresh test enrollment, independently of the bundle source and device locale.
    public static let studyVariant = LaunchOption<StudyVariant?>("--studyVariant", default: nil)
}

#endif
