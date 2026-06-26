//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation


struct ReferralSource: Hashable, Identifiable, Sendable {
    let id: String
    let displayTitle: LocalizedStringResource
}


extension ReferralSource: Codable {
    init?(id: ID) {
        if let option = (Self.options + [.notSet]).first(where: { $0.id == id }) {
            self = option
        } else {
            return nil
        }
    }
    
    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let id = try container.decode(ID.self)
        if let option = Self(id: id) {
            self = option
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Unknown id '\(id)'"))
        }
    }
    
    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(id)
    }
}


extension ReferralSource: DemographicsSelectableSimpleValue {
    static let notSet = Self(id: "0", displayTitle: "Not Set")
    static let preferNotToState: Self? = nil
    
    static let options: [Self] = [
        Self(id: "1", displayTitle: "REFERRAL_OPTION_1"),
        Self(id: "2", displayTitle: "REFERRAL_OPTION_2"),
        Self(id: "3", displayTitle: "REFERRAL_OPTION_3"),
        Self(id: "4", displayTitle: "REFERRAL_OPTION_4"),
        Self(id: "5", displayTitle: "REFERRAL_OPTION_5"),
        Self(id: "6", displayTitle: "REFERRAL_OPTION_6"),
        Self(id: "7", displayTitle: "REFERRAL_OPTION_7"),
        Self(id: "8", displayTitle: "REFERRAL_OPTION_8"),
        Self(id: "9", displayTitle: "REFERRAL_OPTION_9"),
        Self(id: "10", displayTitle: "REFERRAL_OPTION_10"),
        Self(id: "11", displayTitle: "REFERRAL_OPTION_11")
    ]
    
    var rawValue: String { id }
}
