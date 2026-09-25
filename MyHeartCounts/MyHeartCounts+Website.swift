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
    
    /// Returns the official My Heart Counts study website, for the specified region.
    ///
    /// - parameter region: The region whose website should be returned. If omitted, the region is determined based on the app's available context.
    @MainActor
    static func website(_ selector: WebsiteSelector, for region: Locale.Region? = nil) -> URL {
        switch region {
        case .none:
            return website(selector, for: DeferredConfigLoading.activeStudyVariant?.region ?? Locale.current.region ?? .unitedStates)
        case .some(.unitedKingdom):
            // TASK: swap out for UK websites once available
            return switch selector {
            case .homepage:
                "https://myheartcounts.stanford.edu"
            case .privacyPolicy:
                "https://myheartcounts.stanford.edu/privacy"
            }
        case .some:
            return switch selector {
            case .homepage:
                "https://myheartcounts.stanford.edu"
            case .privacyPolicy:
                "https://myheartcounts.stanford.edu/privacy"
            }
        }
    }
}
