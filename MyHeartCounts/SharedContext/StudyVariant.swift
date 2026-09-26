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
}
