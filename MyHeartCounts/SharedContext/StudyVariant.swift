//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveAccount
import GroveLocalization
import GroveStudy
import MHCStudyDefinition


extension AccountDetails {
    /// Accounts enrolled before the variant field existed belong to the original Stanford study.
    var existingStudyVariant: StudyVariant? {
        studyVariant ?? (dateOfEnrollment != nil ? .stanford : nil)
    }
}


extension StudyVariant {
    /// The study variant whose texts the app presents: the active variant, else the build's forced variant, else Stanford.
    @MainActor static var current: StudyVariant {
        DeferredConfigLoading.activeStudyVariant ?? FeatureFlags.forcedStudyVariant ?? .stanford
    }

    var region: Locale.Region {
        switch self {
        case .stanford: .unitedStates
        case .imperial: .unitedKingdom
        }
    }

    var preferredLocale: Locale {
        Locale(language: Locale.current.language.withRegion(nil), region: region)
    }

    /// The variant's news feed within the connected backend's Storage bucket.
    var newsStoragePath: String {
        switch self {
        case .stanford: "/public/news/"
        case .imperial: "/public/news-UK/"
        }
    }

    /// Selects the variant-specific version of a localized text.
    ///
    /// Study variant is a localization axis separate from language: variant-dependent texts use one string catalog key per variant,
    /// each localized into all app languages as usual. Every variant is spelled out, so that adding one makes the compiler flag each call site.
    func localized(stanford: LocalizedStringResource, imperial: LocalizedStringResource) -> LocalizedStringResource {
        switch self {
        case .stanford: stanford
        case .imperial: imperial
        }
    }

    /// Imperial currently has an English consent only; eligibility asks participants to confirm that language.
    func consentLocale(preferred locale: Locale) -> Locale {
        Locale(
            languageCode: self == .imperial ? .english : locale.language.languageCode,
            languageRegion: region
        )
    }
}
