//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import SpeziLocalization


/// The study protocol and regional resources, independent of the Firebase deployment hosting them.
enum StudyVariant: String, Codable, Sendable {
    case stanford
    case imperial

    var region: Locale.Region {
        switch self {
        case .stanford: .unitedStates
        case .imperial: .unitedKingdom
        }
    }

    var preferredLocale: Locale {
        Locale(language: Locale.current.language.withRegion(nil), region: region)
    }

    var studyBundleFilename: String {
        switch self {
        case .stanford: "mhcStudyBundle"
        case .imperial: "mhcStudyBundle-UK"
        }
    }

    /// The variant's news feed within the connected backend's Storage bucket.
    var newsStoragePath: String {
        switch self {
        case .stanford: "/public/news/"
        case .imperial: "/public/news-UK/"
        }
    }
}
