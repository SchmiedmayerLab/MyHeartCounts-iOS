//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation


/// The ethnic groups of the 2021 UK census (England and Wales).
struct EthnicityUK: DemographicsSelectableSimpleValue {
    let id: String
    let displayTitle: LocalizedStringResource
    let displaySubtitle: LocalizedStringResource?

    var rawValue: String { id }

    init(id: String, title: LocalizedStringResource, group: LocalizedStringResource? = nil) {
        self.id = id
        self.displayTitle = title
        self.displaySubtitle = group
    }
}

extension EthnicityUK {
    static let notSet = Self(id: "notSet", title: "Not Set")
    static let preferNotToState: Self? = Self(id: "preferNotToSay", title: "Prefer not to say")

    static let options: [Self] = [
        Self(id: "whiteBritish", title: "English, Welsh, Scottish, Northern Irish or British", group: "White"),
        Self(id: "whiteIrish", title: "Irish", group: "White"),
        Self(id: "whiteGypsyOrIrishTraveller", title: "Gypsy or Irish Traveller", group: "White"),
        Self(id: "whiteRoma", title: "Roma", group: "White"),
        Self(id: "whiteOther", title: "Any other White background", group: "White"),
        Self(id: "mixedWhiteAndBlackCaribbean", title: "White and Black Caribbean", group: "Mixed or Multiple ethnic groups"),
        Self(id: "mixedWhiteAndBlackAfrican", title: "White and Black African", group: "Mixed or Multiple ethnic groups"),
        Self(id: "mixedWhiteAndAsian", title: "White and Asian", group: "Mixed or Multiple ethnic groups"),
        Self(id: "mixedOther", title: "Any other Mixed or Multiple ethnic background", group: "Mixed or Multiple ethnic groups"),
        Self(id: "asianIndian", title: "Indian", group: "Asian or Asian British"),
        Self(id: "asianPakistani", title: "Pakistani", group: "Asian or Asian British"),
        Self(id: "asianBangladeshi", title: "Bangladeshi", group: "Asian or Asian British"),
        Self(id: "asianChinese", title: "Chinese", group: "Asian or Asian British"),
        Self(id: "asianOther", title: "Any other Asian background", group: "Asian or Asian British"),
        Self(id: "blackCaribbean", title: "Caribbean", group: "Black, Black British, Caribbean or African"),
        Self(id: "blackAfrican", title: "African", group: "Black, Black British, Caribbean or African"),
        Self(id: "blackOther", title: "Any other Black, Black British or Caribbean background", group: "Black, Black British, Caribbean or African"),
        Self(id: "otherArab", title: "Arab", group: "Other ethnic group"),
        Self(id: "otherAny", title: "Any other ethnic group", group: "Other ethnic group")
    ]
}
