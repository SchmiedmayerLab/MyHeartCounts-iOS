//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import SpeziConsent


extension ConsentDocument.UserResponses {
    struct ToggleKey: RawRepresentable, Hashable, Sendable {
        let rawValue: String
    }
    
    struct SelectKey: RawRepresentable, Hashable, Sendable {
        let rawValue: String
    }
    
    struct SelectOptionKey: RawRepresentable, Hashable, Sendable {
        let rawValue: String
    }
    
    
    func toggleValue(for key: ToggleKey) -> Bool? { // swiftlint:disable:this discouraged_optional_boolean
        toggles[key.rawValue]
    }
    
    func selectedOption(for key: SelectKey) -> SelectOptionKey? {
        selects[key.rawValue].map { .init(rawValue: $0) }
    }
}


// MARK: MHC-spezific keys (needs to be sync'd with the Consent.md files!)

extension ConsentDocument.UserResponses.ToggleKey {
    static let futureStudiesOptIn = Self(rawValue: "future-studies")
}

extension ConsentDocument.UserResponses.SelectKey {
    static let trialOptIn = Self(rawValue: "short-term-physical-activity-trial")
}


extension ConsentDocument.UserResponses.SelectOptionKey {
    static let trialYes = Self(rawValue: "short-term-physical-activity-trial-yes")
    static let trialNo = Self(rawValue: "short-term-physical-activity-trial-no")
}
