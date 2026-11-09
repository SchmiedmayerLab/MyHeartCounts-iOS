//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import GroveConsent


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
    
    
    /// Whether the participant agreed to be contacted about future studies.
    ///
    /// The Stanford consent asks this with a toggle, the Imperial consent with a Yes/No choice.
    var futureStudiesOptIn: Bool {
        toggleValue(for: .futureStudiesOptIn) ?? (selectedOption(for: .futureStudiesOptIn) == .futureStudiesYes)
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
    static let futureStudiesOptIn = Self(rawValue: "future-studies")
}


extension ConsentDocument.UserResponses.SelectOptionKey {
    static let futureStudiesYes = Self(rawValue: "future-studies-yes")
    static let trialYes = Self(rawValue: "short-term-physical-activity-trial-yes")
    static let trialNo = Self(rawValue: "short-term-physical-activity-trial-no")
}
