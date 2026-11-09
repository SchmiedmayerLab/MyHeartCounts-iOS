//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation


/// The top-level ethnic groups of the UK government's ethnicity question.
struct EthnicityUK: DemographicsSelectableSimpleValue {
    let id: String
    let displayTitle: LocalizedStringResource

    var rawValue: String { id }

    init(id: String, title: LocalizedStringResource) {
        self.id = id
        self.displayTitle = title
    }
}

extension EthnicityUK {
    static let notSet = Self(id: "notSet", title: "Not Set")
    static let preferNotToState: Self? = Self(id: "preferNotToSay", title: "Prefer not to say")

    static let options: [Self] = [
        Self(id: "white", title: "White"),
        Self(id: "mixedOrMultiple", title: "Mixed or multiple ethnic groups"),
        Self(id: "asianOrAsianBritish", title: "Asian or Asian British"),
        Self(id: "blackAfricanCaribbeanOrBlackBritish", title: "Black, African, Caribbean or Black British"),
        Self(id: "other", title: "Other ethnic group")
    ]
}
