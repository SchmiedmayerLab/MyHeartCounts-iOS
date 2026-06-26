//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation


struct LatinoStatusOption: RawRepresentableAccountKey, DemographicsSelectableSimpleValue {
    let rawValue: UInt8
    let displayTitle: LocalizedStringResource
    
    var id: some Hashable {
        rawValue
    }
    
    init(rawValue: UInt8, displayTitle: LocalizedStringResource) {
        self.rawValue = rawValue
        self.displayTitle = displayTitle
    }
    
    init?(rawValue: UInt8) {
        let allOptions: [Self] = Self.options + [.notSet, .preferNotToState].compactMap(\.self)
        guard let option = allOptions.first(where: { $0.rawValue == rawValue }) else {
            return nil
        }
        self = option
    }
}

extension LatinoStatusOption {
    static let notSet = Self(rawValue: 0, displayTitle: "Not Set")
    static let preferNotToState: Self? = Self(rawValue: .max, displayTitle: "Prefer not to state")
    
    static let options: [Self] = [
        Self(rawValue: 1, displayTitle: "No"),
        Self(rawValue: 2, displayTitle: "Yes, Mexican, Mexican American, or Chicano"),
        Self(rawValue: 3, displayTitle: "Yes, Caribbean Hispanic, including Cuban and Puerto Rican"),
        Self(rawValue: 4, displayTitle: "Yes, South American Hispanic"),
        Self(rawValue: 5, displayTitle: "Yes, European Hispanic, including Spanish and Portuguese, Hispanic, Latina"),
        Self(rawValue: 6, displayTitle: "Yes, other Hispanic, Latino")
    ]
}
