//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import MyHeartCountsShared
import SpeziFoundation


extension MyHeartCounts {
    enum WebsiteSelector {
        case homepage
        case privacyPolicy
    }
    
    /// Returns the official My Heart Counts study website for the specified study variant.
    ///
    /// - parameter variant: Defaults to the active study variant, or Stanford before a variant has been selected.
    @MainActor
    static func website(_ selector: WebsiteSelector, for variant: StudyVariant? = nil) -> URL {
        switch variant ?? DeferredConfigLoading.activeStudyVariant ?? .stanford {
        case .imperial:
            return switch selector {
            case .homepage:
                "https://www.imperial.ac.uk/nhli/research/my-heart-counts/"
            case .privacyPolicy:
                // TASK: Replace this placeholder with the Imperial study's privacy policy once available.
                "https://myheartcounts.stanford.edu/privacy"
            }
        case .stanford:
            return switch selector {
            case .homepage:
                "https://myheartcounts.stanford.edu"
            case .privacyPolicy:
                "https://myheartcounts.stanford.edu/privacy"
            }
        }
    }
}
