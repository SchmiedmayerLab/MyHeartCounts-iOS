//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFoundation
import MHCStudyDefinition
import MyHeartCountsShared


extension MyHeartCounts {
    /// Returns the official My Heart Counts study website for the specified study variant.
    ///
    /// - parameter variant: Defaults to the active study variant, or Stanford before a variant has been selected.
    @MainActor
    static func website(for variant: StudyVariant? = nil) -> URL {
        switch variant ?? DeferredConfigLoading.activeStudyVariant ?? .stanford {
        case .imperial:
            "https://www.imperial.ac.uk/nhli/research/my-heart-counts/"
        case .stanford:
            "https://myheartcounts.stanford.edu"
        }
    }
}
